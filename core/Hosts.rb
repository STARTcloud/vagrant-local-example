# coding: utf-8

# This class takes the Hosts.yaml and set's the neccessary variables to run provider specific sequences to boot a VM.
class Hosts
  def Hosts.configure(config, settings)
    ## Load the variable definitions

    ## Load your Secrets file
    secrets = YAML::load(File.read("#{File.dirname(__FILE__)}/.secrets.yml")) if File.exists?("#{File.dirname(__FILE__)}/../.secrets.yml")

    # Main loop to configure VM
    settings['hosts'].each_with_index do |host, index|
      provider = host['settings']['provider-type']

      if host.has_key?('plugins')
        host['plugins'].each do |plugin|
          unless Vagrant.has_plugin?("#{plugin}")
            system("vagrant plugin install #{plugin}")
            exit system('vagrant', *ARGV)
          end
        end
      end

      ENV['VAGRANT_NO_PARALLEL'] = 'yes'
      ENV['VAGRANT_NO_PARALLEL'] = 'no' if host['settings'].has_key?('parallel') && host['settings']['parallel']
 
      config.vm.define "#{host['settings']['server_id']}--#{host['settings']['hostname']}.#{host['settings']['domain']}" do |server|

        #Box Settings -- Used in downloading and packaging Vagrant boxes
        server.vm.box = host['settings']['box']
        server.vm.boot_timeout = host['settings']['setup_wait']

        # Setup SSH and Prevent TTY errors
        server.ssh.username = host['settings']['user']
        #server.ssh.password =  host['settings']['password']
        server.ssh.private_key_path = host['settings']['private_key_path']
        #server.ssh.insert_key = host['settings']['vagrant_insert_key']
        #server.ssh.forward_agent = host['settings']['ssh_forward_agent']
        config.vm.communicator = :ssh
        config.winrm.username = host['settings']['user']
        config.winrm.password = host['settings']['password']
        config.winrm.timeout = host['settings']['setup_wait']
        config.winrm.retry_delay = 30
        config.winrm.retry_limit = 1000

        ## Networking
        ## Note Do not place two IPs in the same subnet on both nics at the same time, They must be different subnets or on a different network segment(ie VLAN, physical seperation for Linux VMs)
        if host.has_key?('networks') && !host['networks'].nil?
          host['networks'].each_with_index do |network, netindex|
              if network['type'] == 'external'
                server.vm.network "public_network",
                  ip: network['address'],
                  dhcp4: network['dhcp4'],
                  dhcp6: network['dhcp6'],
                  bridge: network['bridge'],
                  auto_config: network['autoconf'],
                  netmask: network['netmask'],
                  mac: network['mac'],
                  gateway: network['gateway'],
                  nictype: network['type'],
                  nic_number: netindex,
                  managed: network['is_control'],
                  vlan: network['vlan'],
                  dns: network['dns'],
                  provisional: network['provisional'],
                  route: network['route']
              end
              if network['type'] == 'host'
                server.vm.network "private_network",
                  ip: network['address'],
                  dhcp4: network['dhcp4'],
                  dhcp6: network['dhcp6'],
                  bridge: network['bridge'],
                  auto_config: network['autoconf'],
                  netmask: network['netmask'],
                  mac: network['mac'],
                  gateway: network['gateway'],
                  nictype: network['type'],
                  nic_number: netindex,
                  managed: network['is_control'],
                  vlan: network['vlan'],
                  dns: network['dns'],
                  provisional: network['provisional'],
                  route: network['route']
              end
          end
        end

        server.vm.provider provider.to_sym do |vm|
          vm.vagrant_user_private_key_path = host['settings']['private_key_path']
        end


        # Register shared folders
        if host.has_key?('folders')
          host['folders'].each do |folder|
            mount_opts = folder['type'] == folder['type'] ? ['actimeo=1'] : []
            server.vm.synced_folder folder['map'], folder ['to'],
            type: folder['type'],
            owner: folder['owner'] ||= host['settings']['user'],
            group: folder['group'] ||= host['settings']['user'],
            mount_options: mount_opts,
            automount: true,
            rsync__args: folder['args'] ||= ["--verbose", "--archive", "-z", "--copy-links"],
            rsync__chown:  folder['chown'] ||= 'false',
            create: folder['create'] ||= 'false',
            rsync__rsync_ownership:  folder['rsync_ownership'] ||= 'true',
            disabled: folder['disabled']||= false
          end
        end

        # Add Branch Files to Vagrant Share on VM Change to Git folders to pull
        scriptsPath = File.dirname(__FILE__) + '/scripts'
        if host['provisioning'].has_key?('role') && host['provisioning']['role']['enabled']
            server.vm.provision 'shell' do |s|
              s.path = scriptsPath + '/add-role.sh'
              s.args = [host['provisioning']['role']['name'], host['provisioning']['role']['git_url'] ]
            end
        end

        # Run the shell provisioners defined in hosts.yml
        if host['provisioning'].has_key?('shell') && host['provisioning']['shell']['enabled']
          host['provisioning']['shell']['scripts'].each do |file|
              server.vm.provision 'shell', path: file
          end
        end

        # Run the Ansible Provisioners -- You can pass Host.yaml variables to Ansible via the Extra_vars variable as noted below.
        ## If Ansible is not available on the host and is installed in the template you are spinning up, use 'ansible-local'
        if host['provisioning'].has_key?('ansible') && host['provisioning']['ansible']['enabled']
          host['provisioning']['ansible']['scripts'].each do |scripts|
            if scripts.has_key?('local')
              scripts['local'].each do |localscript|
                server.vm.provision :ansible_local do |ansible|
                  ansible.playbook = localscript['script']
                  ansible.compatibility_mode = localscript['compatibility_mode'].to_s
                  ansible.install_mode = "pip" if localscript['install_mode'] == "pip"
                  ansible.verbose = localscript['verbose']
                  ansible.extra_vars = {
                    settings: host['settings'],
                    networks: host['networks'],
                    disks: host['disks'],
                    secrets: secrets,
                    provision_roles: host['roles'],
                    role_vars: host['vars'],
                    ansible_callbacks_enabled: "profile_tasks",
                    ansible_winrm_server_cert_validation: "ignore",
                    ansible_ssh_pipelining:localscript['ssh_pipelining'],
                    ansible_python_interpreter:localscript['ansible_python_interpreter']}
                end
              end
            end

            ## If Ansible is available on the host or is not installed in the template you are spinning up, use 'ansible'
            if scripts.has_key?('remote')
              scripts['remote'].each do |remotescript|
                server.vm.provision :ansible do |ansible|
                  ansible.playbook = remotescript['script']
                  ansible.compatibility_mode = remotescript['compatibility_mode'].to_s
                  ansible.verbose = remotescif host.has_key?('networks') && host['settings']['provider-type'] == 'virtualbox'
                  host['networks'].each_with_index do |network, netindex|
                    config.trigger.after [:up] do |trigger|
                      trigger.ruby do |env,machine|
                        puts "This server has been provisioned with DemoTasks Roles v" + DemoTasks::VERSION
                        puts "https://github.com/DominoVagrant/demo-tasks/releases/tag/v" + DemoTasks::VERSION
                        ipaddress = network['address']
                        system("vagrant ssh -c 'cat /vagrant/completed/ipaddress.yml' > .vagrant/provisioned-briged-ip.txt")
                        ipaddress = File.readlines(".vagrant/provisioned-briged-ip.txt").join("") if network['dhcp4']
                        open_url = "https://" + ipaddress + ":443/welcome.html"
                        system("echo '" + open_url + "' > .vagrant/done.txt")
                      end
                    end
                  end
                endript['verbose']
                  ansible.extra_vars = {
                      settings: host['settings'],
                      networks: host['networks'],
                      disks: host['disks'],
                      secrets: secrets,
                      role_vars: host['vars'],
                      provision_roles: host['roles'],
                      ansible_callbacks_enabled: "profile_tasks",
                      ansible_winrm_server_cert_validation: "ignore",
                      ansible_ssh_pipelining:remotescript['ssh_pipelining'],
                      ansible_python_interpreter:remotescript['ansible_python_interpreter']
                    }
                end
              end
            end
          end
        end

        # Run the Docker-Compose provisioners defined in hosts.yml
        if host['provisioning'].has_key?('docker') && host['provisioning']['docker']['enabled']
          host['provisioning']['docker']['docker_compose'].each do |file|
              server.vm.provision 'docker'
              server.vm.provision :docker_compose, yml: file, run: "always"
          end
        end
      end

    end
  end
end
