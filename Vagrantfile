## Vagrant File tooling compatabile with Bhyve and Virtualbox, potentially ESXI/Vmware,KVM
require_relative 'core/Hosts'
require 'yaml'
settings = YAML.load_file("#{File.dirname(__FILE__)}/Hosts.yml")
Vagrant.configure("2") { |config| Hosts.configure(config, settings) }