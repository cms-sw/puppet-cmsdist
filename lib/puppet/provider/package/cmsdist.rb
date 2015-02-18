require "pathname"
require "puppet/provider/package"
require "puppet/util/execution"

Puppet::Type.type(:package).provide :cmsdist, :parent => Puppet::Provider::Package do
  include Puppet::Util::Execution

  desc "CMS packages via apt-get."

  has_feature :unversionable
  has_feature :install_options

  def self.home
    if boxen_home = Facter.value(:boxen_home)
      "#{boxen_home}/homebrew"
    else
      "/opt/cms"
    end
  end

  def self.default_architecture
    "slc6_amd64_gcc481"
  end

  def self.default_cms_user
    "cmsbuild"
  end

  def self.default_repository
    return "cms"
  end

  def self.default_server
    return "cmsrep.cern.ch"
  end

  def self.default_server_path
    return "cmssw/cms"
  end

  def get_install_options
    if @resource[:install_options].is_a?(Array)
      return @resource[:install_options][0]
    elsif @resource[:install_options].is_a?(Hash)
      return @resource[:install_options]
    else
      Puppet.debug "install_options not specified. Using default."
      return {}
    end
  end

  def self.bootstrapped?(architecture, prefix)
    Puppet.debug "Checking if #{architecture} bootstrapped in #{prefix}."
    return Kernel.system "source #{prefix}/#{architecture}/external/apt/*/etc/profile.d/init.sh 2>/dev/null; which apt-get 2>&1 >/dev/null"
  end

  # Helper function to boostrap a CMSSW environment.
  def bootstrap(architecture, prefix, user, repository, server, server_path)
    if self.class.bootstrapped?(architecture, prefix)
      Puppet.debug("Bootstrap previously done.")
      return
    end
    Puppet.debug("Creating #{prefix} and assigning it to #{user}")
    execute ["mkdir", "-p", prefix]
    execute ["chown", user, prefix]
    Puppet.debug("Fetching bootstrap from #{repository}")
    execute ["wget", "--no-check-certificate", "-O",
             File.join([prefix, "bootstrap-#{architecture}.sh"]),
             "#{server}/#{server_path}/bootstrap.sh"]
    Puppet.debug("Installing CMS bootstrap.")
    execute ["sudo", "-u", user,
             "sh", "-x", File.join([prefix, "bootstrap-#{architecture}.sh"]),
             "setup",
             "-path", prefix,
             "-arch", architecture,
             "-server", server,
             "-server-path", server_path,
             "-assume-yes"]
    Puppet.debug("Bootstrap completed")
  end

  def install
    opts = self.get_install_options
    prefix = (opts["install_prefix"] or self.class.home)
    architecture = (opts["architecture"] or self.class.default_architecture)
    user = (opts["install_user"] or self.class.default_cms_user)
    repository = (opts["repository"] or self.class.default_repository)
    server = (opts["server"] or self.class.default_server)
    server_path = (opts["server_path"] or self.class.default_server_path)
    fullname, overwrite_architecture = @resource[:name].split "/"
    architecture = (overwrite_architecture and overwrite_architecture or architecture)
    group, package, version = fullname.split "+"
    bootstrap(architecture, prefix, user, repository, server, server_path)
    output = `sudo -u #{user} bash -c 'source #{prefix}/#{architecture}/external/apt/*/etc/profile.d/init.sh 2>&1;  apt-get update ; apt-get install -y #{fullname} 2>&1 && apt-get clean -y'`
    Puppet.debug output
    if $?.to_i != 0
      raise Puppet::Error, "Could not install package. #{output}"
    end
    $?.to_i
  end

  def uninstall
    opts = self.get_install_options
    prefix = (opts["install_prefix"] or self.class.home)
    architecture = (opts["architecture"] or self.class.default_architecture)
    user = (opts["install_user"] or self.class.default_cms_user)
    repository = (opts["repository"] or self.class.default_repository)
    server = (opts["server"] or self.class.default_server)
    server_path = (opts["server_path"] or self.class.default_server_path)
    fullname, overwrite_architecture = @resource[:name].split "/"
    architecture = (overwrite_architecture and overwrite_architecture or architecture)
    group, package, version = fullname.split "+"
    output = `sudo -u #{user} bash -c 'source #{prefix}/#{architecture}/external/apt/*/etc/profile.d/init.sh 2>&1;  apt-get update ; apt-get remove -y #{fullname} 2>&1'`
    Puppet.debug output
    if $?.to_i != 0
      raise Puppet::Error, "Could not remove package. #{output}"
    end
    $?.to_i
  end

  def query
    opts = self.get_install_options
    prefix = (opts["install_prefix"] or self.class.home)
    architecture = (opts["architecture"] or self.class.default_architecture)
    user = (opts["install_user"] or self.class.default_cms_user)
    repository = (opts["repository"] or self.class.default_repository)
    server = (opts["server"] or self.class.default_server)
    server_path = (opts["server_path"] or self.class.default_server_path)
    Puppet.debug "query invoked with #{prefix} #{architecture} #{user}"
    fullname, overwrite_architecture = @resource[:name].split "/"
    architecture = (overwrite_architecture and overwrite_architecture or architecture)
    group, package, version = fullname.split "+"
    bootstrap(architecture, prefix, user, repository, server, server_path)
    existance = File.exists? File.join([prefix, architecture, group, package,
                                        version])
    if not existance
      return nil
    else
      return { :ensure => "1.0", :name => @resource[:name] }
    end
  end

  def self.listPackages
    Puppet.debug "Listing packages in /opt/cms"
    prefix = "/opt/cms"
    architectures = Dir.entries(prefix).select{|f|
      f.match /^(slc|osx|fc|cc)[0-9]/
    }
    Puppet.debug "Found following architectures in #{prefix}: #{architectures}"
    packages = []
    architectures.collect {|architecture|
      output = "\n" + `bash -c 'source #{prefix}/#{architecture}/external/apt/*/etc/profile.d/init.sh 2>&1 >/dev/null; rpm -qa'`.chomp
      Puppet.debug output
      packagesList = output.split(/\n/)
      packagesList.reject! {|p| p.chomp == ""}
      packages.concat(packagesList.collect {|name|
        {
          :name => name + "/#{architecture}",
          :ensure => "present", 
          :install_options => {
            :architecture => architecture,
            :prefix => prefix
          }
        }
      })
    }
    packages
  end
  
  def self.instances
    self.listPackages().collect do |hash|
      new(hash)
    end
  end

  # Override default `execute` to run super method in a clean
  # environment without Bundler, if Bundler is present
  def execute(*args)
    if Puppet.features.bundled_environment?
      Bundler.with_clean_env do
        super
      end
    else
      super
    end
  end

  # Override default `execute` to run super method in a clean
  # environment without Bundler, if Bundler is present
  def self.execute(*args)
    if Puppet.features.bundled_environment?
      Bundler.with_clean_env do
        super
      end
    else
      super
    end
  end
end
