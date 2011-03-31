#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2010 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'fog'
require 'socket'
require 'chef/knife'
require 'chef/knife/bootstrap'
require 'chef/json_compat'

class Chef
  class Knife
    class Ec2ServerCreate < Knife

      deps do
        Chef::Knife::Bootstrap.load_deps
        require 'fog'
        require 'highline'
        require 'net/ssh/multi'
        require 'readline'
      end

      banner "knife ec2 server create (options)"

      attr_accessor :initial_sleep_delay

      option :flavor,
        :short => "-f FLAVOR",
        :long => "--flavor FLAVOR",
        :description => "The flavor of server (m1.small, m1.medium, etc)",
        :proc => Proc.new { |f| Chef::Config[:knife][:flavor] = f },
        :default => "m1.small"

      option :image,
        :short => "-I IMAGE",
        :long => "--image IMAGE",
        :description => "The AMI for the server",
        :proc => Proc.new { |i| Chef::Config[:knife][:image] = i }

      option :security_groups,
        :short => "-G X,Y,Z",
        :long => "--groups X,Y,Z",
        :description => "The security groups for this server",
        :default => ["default"],
        :proc => Proc.new { |groups| groups.split(',') }

      option :availability_zone,
        :short => "-Z ZONE",
        :long => "--availability-zone ZONE",
        :description => "The Availability Zone",
        :default => "us-east-1b",
        :proc => Proc.new { |key| Chef::Config[:knife][:availability_zone] = key }

      option :chef_node_name,
        :short => "-N NAME",
        :long => "--node-name NAME",
        :description => "The Chef node name for your new node"

      option :ssh_key_name,
        :short => "-S KEY",
        :long => "--ssh-key KEY",
        :description => "The AWS SSH key id",
        :proc => Proc.new { |key| Chef::Config[:knife][:aws_ssh_key_id] = key }

      option :ssh_user,
        :short => "-x USERNAME",
        :long => "--ssh-user USERNAME",
        :description => "The ssh username",
        :default => "root"

      option :ssh_password,
        :short => "-P PASSWORD",
        :long => "--ssh-password PASSWORD",
        :description => "The ssh password"

      option :identity_file,
        :short => "-i IDENTITY_FILE",
        :long => "--identity-file IDENTITY_FILE",
        :description => "The SSH identity file used for authentication"

      option :aws_access_key_id,
        :short => "-A ID",
        :long => "--aws-access-key-id KEY",
        :description => "Your AWS Access Key ID",
        :proc => Proc.new { |key| Chef::Config[:knife][:aws_access_key_id] = key }

      option :aws_secret_access_key,
        :short => "-K SECRET",
        :long => "--aws-secret-access-key SECRET",
        :description => "Your AWS API Secret Access Key",
        :proc => Proc.new { |key| Chef::Config[:knife][:aws_secret_access_key] = key }

      option :prerelease,
        :long => "--prerelease",
        :description => "Install the pre-release chef gems"

      option :region,
        :long => "--region REGION",
        :description => "Your AWS region",
        :default => "us-east-1",
        :proc => Proc.new { |key| Chef::Config[:knife][:region] = key }

      option :distro,
        :short => "-d DISTRO",
        :long => "--distro DISTRO",
        :description => "Bootstrap a distro using a template",
        :proc => Proc.new { |d| Chef::Config[:knife][:distro] = d },
        :default => "ubuntu10.04-gems"

      option :template_file,
        :long => "--template-file TEMPLATE",
        :description => "Full path to location of template to use",
        :proc => Proc.new { |t| Chef::Config[:knife][:template_file] = t },
        :default => false

      option :ebs_size,
        :long => "--ebs-size SIZE",
        :description => "The size of the EBS volume in GB, for EBS-backed instances"

      option :ebs_no_delete_on_term,
        :long => "--ebs-no-delete-on-term",
        :description => "Do not delete EBS volumn on instance termination"

      option :run_list,
        :short => "-r RUN_LIST",
        :long => "--run-list RUN_LIST",
        :description => "Comma separated list of roles/recipes to apply",
        :proc => lambda { |o| o.split(/[\s,]+/) },
        :default => []

      option :subnet_id,
        :short => "-s SUBNET-ID",
        :long => "--subnet SUBNET-ID",
        :description => "create node in this Virtual Private Cloud Subnet ID (implies VPC mode)",
        :default => false

      option :no_host_key_verify,
        :long => "--no-host-key-verify",
        :description => "Disable host key verification",
        :boolean => true,
        :default => false

      def h
        @highline ||= HighLine.new
      end

      def tcp_test_ssh(hostname)
        tcp_socket = TCPSocket.new(hostname, 22)
        readable = IO.select([tcp_socket], nil, nil, 5)
        if readable
          Chef::Log.debug("sshd accepting connections on #{hostname}, banner is #{tcp_socket.gets}")
          yield
          true
        else
          false
        end
      rescue Errno::ETIMEDOUT
        false
      rescue Errno::ECONNREFUSED
        sleep 2
        false
      ensure
        tcp_socket && tcp_socket.close
      end

      def run

        $stdout.sync = true

        connection = Fog::Compute.new(
          :provider => 'AWS',
          :aws_access_key_id => Chef::Config[:knife][:aws_access_key_id],
          :aws_secret_access_key => Chef::Config[:knife][:aws_secret_access_key],
          :region => locate_config_value(:region)
        )

        ami = connection.images.get(locate_config_value(:image))

        server_def = {
          :image_id => locate_config_value(:image),
          :groups => config[:security_groups],
          :flavor_id => locate_config_value(:flavor),
          :key_name => Chef::Config[:knife][:aws_ssh_key_id],
          :availability_zone => Chef::Config[:knife][:availability_zone]
        }
        server_def[:subnet_id] = config[:subnet_id] if config[:subnet_id]

      if ami.root_device_type == "ebs"
        ami_map = ami.block_device_mapping.first
        ebs_size = begin
                     if config[:ebs_size]
                       Integer(config[:ebs_size]).to_s
                     else
                       ami_map["volumeSize"].to_s
                     end
                   rescue ArgumentError
                     puts "--ebs-size must be an integer"
                     msg opt_parser
                     exit 1
                   end
        delete_term = if config[:ebs_no_delete_on_term]
                        "false"
                      else
                        ami_map["deleteOnTermination"]
                      end
        server_def[:block_device_mapping] =
          [{
             'DeviceName' => ami_map["deviceName"],
             'Ebs.VolumeSize' => ebs_size,
             'Ebs.DeleteOnTermination' => delete_term
           }]
      end
        server = connection.servers.create(server_def)

        puts "#{h.color("Instance ID", :cyan)}: #{server.id}"
        puts "#{h.color("Flavor", :cyan)}: #{server.flavor_id}"
        puts "#{h.color("Image", :cyan)}: #{server.image_id}"
        puts "#{h.color("Availability Zone", :cyan)}: #{server.availability_zone}"
        puts "#{h.color("Security Groups", :cyan)}: #{server.groups.join(", ")}"
        puts "#{h.color("SSH Key", :cyan)}: #{server.key_name}"
        puts "#{h.color("Subnet ID", :cyan)}: #{server.subnet_id}" if vpc_mode?

        print "\n#{h.color("Waiting for server", :magenta)}"

        display_name = if vpc_mode?
          server.private_ip_address
        else
          server.dns_name
        end

        # wait for it to be ready to do stuff
        server.wait_for { print "."; ready? }

        puts("\n")

        if !vpc_mode?
          puts "#{h.color("Public DNS Name", :cyan)}: #{server.dns_name}"
          puts "#{h.color("Public IP Address", :cyan)}: #{server.public_ip_address}"
          puts "#{h.color("Private DNS Name", :cyan)}: #{server.private_dns_name}"
        end
        puts "#{h.color("Private IP Address", :cyan)}: #{server.private_ip_address}"

        print "\n#{h.color("Waiting for sshd", :magenta)}"

        ip_to_test = vpc_mode? ? server.private_ip_address : server.public_ip_address
        print(".") until tcp_test_ssh(ip_to_test) {
          sleep @initial_sleep_delay ||= (vpc_mode? ? 40 : 10)
          puts("done")
        }

        bootstrap_for_node(server).run

        puts "\n"
        puts "#{h.color("Instance ID", :cyan)}: #{server.id}"
        puts "#{h.color("Flavor", :cyan)}: #{server.flavor_id}"
        puts "#{h.color("Image", :cyan)}: #{server.image_id}"
        puts "#{h.color("Availability Zone", :cyan)}: #{server.availability_zone}"
        puts "#{h.color("Security Groups", :cyan)}: #{server.groups.join(", ")}"
        if vpc_mode?
          puts "#{h.color("Subnet ID", :cyan)}: #{server.subnet_id}"
        else
          puts "#{h.color("Public DNS Name", :cyan)}: #{server.dns_name}"
          puts "#{h.color("Public IP Address", :cyan)}: #{server.public_ip_address}"
          puts "#{h.color("Private DNS Name", :cyan)}: #{server.private_dns_name}"
        end
        puts "#{h.color("SSH Key", :cyan)}: #{server.key_name}"
        puts "#{h.color("Private IP Address", :cyan)}: #{server.private_ip_address}"
        puts "#{h.color("Root Device Type", :cyan)}: #{server.root_device_type}"
        if server.root_device_type == "ebs"
          device_map = server.block_device_mapping.first
          puts "#{h.color("Root Volume ID", :cyan)}: #{device_map['volumeId']}"
          puts "#{h.color("Root Device Name", :cyan)}: #{device_map['deviceName']}"
          puts "#{h.color("Root Device Delete on Terminate", :cyan)}: #{device_map['deleteOnTermination']}"
          if config[:ebs_size]
            if ami.block_device_mapping.first['volumeSize'].to_i < config[:ebs_size].to_i
              puts ("#{h.color("Warning", :yellow)}: #{config[:ebs_size]}GB " +
                    "EBS volume size is larger than size set in AMI of " +
                    "#{ami.block_device_mapping.first['volumeSize']}GB.\n" +
                    "Use file system tools to make use of the increased volume size.")
            end
          end
        end
        puts "#{h.color("Run List", :cyan)}: #{@name_args.join(', ')}"
      end

      def bootstrap_for_node(server)
        bootstrap = Chef::Knife::Bootstrap.new
        bootstrap.name_args = [vpc_mode? ? server.private_ip_address : server.dns_name ]
        bootstrap.config[:run_list] = config[:run_list]
        bootstrap.config[:ssh_user] = config[:ssh_user]
        bootstrap.config[:identity_file] = config[:identity_file]
        bootstrap.config[:chef_node_name] = config[:chef_node_name] || server.id
        bootstrap.config[:prerelease] = config[:prerelease]
        bootstrap.config[:distro] = locate_config_value(:distro)
        bootstrap.config[:use_sudo] = true
        bootstrap.config[:template_file] = locate_config_value(:template_file)
        bootstrap.config[:environment] = config[:environment]
        # may be needed for vpc_mode
        bootstrap.config[:no_host_key_verify] = config[:no_host_key_verify]
        bootstrap
      end

      def locate_config_value(key)
        key = key.to_sym
        Chef::Config[:knife][key] || config[key]
      end

      def vpc_mode?
        # Amazon Virtual Private Cloud requires a subnet_id. If
        # present, do a few things differently
        !!config[:subnet_id]
      end

    end
  end
end
