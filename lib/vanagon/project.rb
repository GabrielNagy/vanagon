require 'vanagon/component'
require 'vanagon/environment'
require 'vanagon/platform'
require 'vanagon/project/dsl'
require 'vanagon/utilities'
require 'ostruct'

class Vanagon
  class Project
    include Vanagon::Utilities

    # Numerous attributes related to the artifact that a given
    # Vanagon project will produce
    attr_accessor :name
    attr_accessor :version
    attr_accessor :release
    attr_accessor :license
    attr_accessor :homepage
    attr_accessor :vendor
    attr_accessor :description
    attr_accessor :components
    attr_accessor :conflicts
    attr_accessor :requires
    attr_accessor :replaces
    attr_accessor :provides

    # Platform's abstraction is kind of backwards -- we should refactor
    # how this works, and make it possible for Vanagon to default to all
    # defined platforms if nothing is specified.
    attr_accessor :platform
    attr_accessor :configdir
    attr_accessor :retry_count
    attr_accessor :timeout

    # Store any target directories that should be packed up into
    # the resultant artifact produced by a given Vanagon project.
    attr_accessor :directories

    # This will define any new users that a project should create
    attr_accessor :user

    # This is entirely too Puppet centric, and should be refactored out
    # !depreciate
    # !refactor
    attr_accessor :repo

    # Mark a project as being architecture independent
    attr_accessor :noarch

    # This is macOS specific, and defines the Identifier that macOS should
    # use when it builds a .pkg
    attr_accessor :identifier

    # Stores whether or not a project should cleanup as it builds
    # because the target builder is space-constrained
    attr_accessor :cleanup

    # Stores whether or not Vanagon should write the project's version
    # out into a file inside the package -- do we really need this?
    # !depreciate
    # !refactor
    attr_accessor :version_file

    # Stores the location for the bill-of-materials (a receipt of all
    # files written during) project package assembly
    attr_accessor :bill_of_materials

    # Stores individual settings related to a given Vanagon project,
    # not necessarily the artifact that the project produces
    attr_accessor :settings

    # The overall Environment that a given Vanagon
    # project should pass to each platform
    attr_accessor :environment

    # Extra vars to be set in the spec file or debian rules.
    # Good for setting extra %define or %global things for RPM, or env
    # variables needed in the debian rules file
    # No extra munging will be performed, so these should be set as you want
    # them to appear in your spec/rules files!
    attr_accessor :package_overrides

    # Should we include source packages?
    attr_accessor :source_artifacts

    # Loads a given project from the configdir
    #
    # @param name [String] the name of the project
    # @param configdir [String] the path to the project config file
    # @param platform [Vanagon::Platform] platform to build against
    # @param include_components [List] optional list restricting the loaded components
    # @return [Vanagon::Project] the project as specified in the project config
    # @raise if the instance_eval on Project fails, the exception is reraised
    def self.load_project(name, configdir, platform, include_components = [])
      projfile = File.join(configdir, "#{name}.rb")
      dsl = Vanagon::Project::DSL.new(name, platform, include_components)
      dsl.instance_eval(File.read(projfile), projfile, 1)
      dsl._project
    rescue => e
      $stderr.puts "Error loading project '#{name}' using '#{projfile}':"
      $stderr.puts e
      $stderr.puts e.backtrace.join("\n")
      raise e
    end

    # Project constructor. Takes just the name. Also sets the @name and
    # @platform, and initializes @components, @directories and @settings.
    #
    # @param name [String] name of the project
    # @param platform [Vanagon::Platform] platform for the project to be built for
    # @return [Vanagon::Project] the project with the given name and platform
    def initialize(name, platform)
      @name = name
      @components = []
      @requires = []
      @directories = []
      @settings = {}
      # Environments are like Hashes but with specific constraints
      # around their keys and values.
      @environment = Vanagon::Environment.new
      @platform = platform
      @release = "1"
      @replaces = []
      @provides = []
      @conflicts = []
      @package_overrides = []
      @source_artifacts = false
    end

    # Magic getter to retrieve settings in the project
    def method_missing(method_name, *args)
      if @settings.key?(method_name)
        return @settings[method_name]
      end
      super
    end

    def respond_to_missing?(method_name, include_private = false)
      @settings.key?(method_name) || super
    end

    # Merge the platform's Environment into the project's Environment
    # and return the result. This will produce the top-level Environment
    # in the Makefile, that all components (and their Make targets)
    # will inherit from.
    #
    # @return [Environment] a new Environment, constructed from merging
    #   @platform's Environment with the project's environment.
    def merged_environment
      environment.merge(@platform.environment)
    end

    # Collects all sources and patches into the provided workdir
    #
    # @param workdir [String] directory to stage sources into
    def fetch_sources(workdir)
      @components.each do |component|
        component.get_source(workdir)
        # Fetch secondary sources
        component.get_sources(workdir)
        component.get_patches(workdir)
      end
    end

    # Collects any additional files supplied by components
    #
    # @return [Array] array of files installed by components of the project
    def get_files
      files = []
      files.push @version_file if @version_file
      files.push components.flat_map(&:files)
      files.flatten.uniq
    end

    # Returns a filtered out set of components only including those
    # components necessary to build a specific component. This is a
    # recursive function that will call itself until it gets to a
    # component with no build requirements
    #
    # @param name [String] name of component to add. must be present in configdir/components and named $name.rb currently
    # @return [Array] array of Vanagon::Component including only those required to build "name", or [] if there are none
    def filter_component(name)
      filtered_component = get_component(name)
      return [] if filtered_component.nil?
      included_components = [filtered_component]

      unless filtered_component.build_requires.empty?
        filtered_component.build_requires.each do |build_requirement|
          unless get_component(build_requirement).nil?
            included_components += filter_component(build_requirement)
          end
        end
      end
      included_components.uniq
    end

    # Gets the component with component.name = "name" from the list
    # of project.components
    #
    # @param [String] component name
    # @return [Vanagon::Component] the component with component.name = "name"
    def get_component(name)
      comps = @components.select { |comp| comp.name.to_s == name.to_s }
      raise "ERROR: two or more components with the same name: #{comps.first.name}" if comps.size > 1
      comps.first
    end

    # Collects all of the requires for both the project and its components
    #
    # @return [Array] array of runtime requirements for the project
    def get_requires
      req = []
      req << components.flat_map(&:requires)
      req << @requires
      req.flatten.uniq
    end

    # Collects all of the replacements for the project and its components
    #
    # @return [Array] array of package level replacements for the project
    def get_replaces
      replaces = []
      replaces.push @replaces.flatten
      replaces.push components.flat_map(&:replaces)
      replaces.flatten.uniq
    end

    def has_replaces?
      !get_replaces.empty?
    end

    # Collects all of the conflicts for the project and its components
    def get_conflicts
      conflicts = components.flat_map(&:conflicts) + @conflicts
      # Mash the whole thing down into a flat Array
      conflicts.flatten.uniq
    end

    def has_conflicts?
      !get_conflicts.empty?
    end

    # Grabs a specific service based on which name is passed in
    # note that if the name is wrong or there was no
    # @component.install_service call in the component, this
    # will return nil
    #
    # @param [string] name of service to grab
    # @return [@component.service obj] specific service
    def get_service(name)
      components.each do |component|
        if component.name == name
          return component.service
        end
      end
      return nil
    end

    # Collects all of the provides for the project and its components
    #
    # @return [Array] array of package level provides for the project
    def get_provides
      provides = []
      provides.push @provides.flatten
      provides.push components.flat_map(&:provides)
      provides.flatten.uniq
    end

    def has_provides?
      !get_provides.empty?
    end

    # Checks that the string pkg_state is valid (install OR upgrade).
    # Return vanagon error if invalid
    #
    # @param pkg_state [String] package state input
    def check_pkg_state_string(pkg_state)
      unless ["install", "upgrade"].include? pkg_state
        raise Vanagon::Error, "#{pkg_state} should be a string containing one of 'install' or 'upgrade'"
      end
    end

    # Collects the preinstall packaging actions for the project and its components
    #  for the specified packaging state
    #
    # @param pkg_state [String] the package state we want to run the given scripts for.
    #   Can be one of 'install' or 'upgrade'
    # @return [String] string of Bourne shell compatible scriptlets to execute during the preinstall
    #   phase of packaging during the state of the system defined by pkg_state (either install or upgrade)
    def get_preinstall_actions(pkg_state)
      check_pkg_state_string(pkg_state)
      scripts = components.flat_map(&:preinstall_actions).compact.select { |s| s.pkg_state.include? pkg_state }.map(&:scripts)
      if scripts.empty?
        return ': no preinstall scripts provided'
      else
        return scripts.join("\n")
      end
    end

    # Collects the install trigger scripts for the project for the specified packing state
    #
    # @param pkg_state [String] the package state we want to run the given scripts for.
    #   Can be one of the 'install' or 'upgrade'
    # @return [Hash] of scriptlets to execute during the pkg_state (install or upgrade)
    #   there can be more than one script for each package (key)
    def get_trigger_scripts(pkg_state)
      triggers = Hash.new { |hsh, key| hsh[key] = [] }
      check_pkg_state_string(pkg_state)
      pkgs = components.flat_map(&:install_triggers).compact.select { |s| s.pkg_state.include? pkg_state }
      pkgs.each do |package|
        triggers[package.pkg].push package.scripts
      end
      triggers
    end

    # Grabs the install trigger scripts for the specified pkg
    #
    # @param pkg [String] the pkg we watch for being installed
    def get_install_trigger_scripts(pkg)
      scripts = get_trigger_scripts("install")
      return scripts[pkg].join("\n")
    end

    # Grabs the upgrade trigger scripts for the specified pkg
    #
    # @param pkg [String] the pkg we watch for being upgraded
    def get_upgrade_trigger_scripts(pkg)
      scripts = get_trigger_scripts("upgrade")
      return scripts[pkg].join("\n")
    end

    # Grabs all pkgs that have trigger scripts for 'install' and 'upgrade'
    #
    # @return [Array] a list of all the pkgs that have trigger scripts
    def get_all_trigger_pkgs()
      install_triggers = get_trigger_scripts("install")
      upgrade_triggers = get_trigger_scripts("upgrade")
      packages = (install_triggers.keys + upgrade_triggers.keys).uniq
      return packages
    end

    # Collects the interest triggers for the project and its scripts for the
    #  specified packaging state
    #
    # @param pkg_state [String] the package state we want to run the given scripts for.
    #   Can be one of 'install' or 'upgrade'
    # @return [Array] of OpenStructs of all interest triggers for the pkg_state
    #   Use array of openstructs because we need both interest_name and the scripts
    def get_interest_triggers(pkg_state)
      interest_triggers = []
      check_pkg_state_string(pkg_state)
      interests = components.flat_map(&:interest_triggers).compact.select { |s| s.pkg_state.include? pkg_state }
      interests.each do |interest|
        interest_triggers.push(interest)
      end
      interest_triggers.flatten.compact
    end

    # Collects activate triggers for the project and its components
    #
    # @return [Array] of activate triggers
    def get_activate_triggers()
      components.flat_map(&:activate_triggers).compact.map(&:activate_name)
    end

    # Collects the postinstall packaging actions for the project and it's components
    #  for the specified packaging state
    #
    # @param pkg_state [String] the package state we want to run the given scripts for.
    #   Can be one of 'install' or 'upgrade'
    # @return [String] string of Bourne shell compatible scriptlets to execute during the postinstall
    #   phase of packaging during the state of the system defined by pkg_state (either install or upgrade)
    def get_postinstall_actions(pkg_state)
      scripts = components.flat_map(&:postinstall_actions).compact.select { |s| s.pkg_state.include? pkg_state }.map(&:scripts)
      if scripts.empty?
        return ': no postinstall scripts provided'
      else
        return scripts.join("\n")
      end
    end

    # Collects the preremove packaging actions for the project and it's components
    # for the specified packaging state
    #
    # @param pkg_state [String] the package state we want to run the given scripts for.
    #   Can be one or more of 'removal' or 'upgrade'
    # @return [String] string of Bourne shell compatible scriptlets to execute during the preremove
    #   phase of packaging during the state of the system defined by pkg_state (either removal or upgrade)
    def get_preremove_actions(pkg_state)
      scripts = components.flat_map(&:preremove_actions).compact.select { |s| s.pkg_state.include? pkg_state }.map(&:scripts)
      if scripts.empty?
        return ': no preremove scripts provided'
      else
        return scripts.join("\n")
      end
    end

    # Collects the postremove packaging actions for the project and it's components
    # for the specified packaging state
    #
    # @param pkg_state [String] the package state we want to run the given scripts for.
    #   Can be one or more of 'removal' or 'upgrade'
    # @return [String] string of Bourne shell compatible scriptlets to execute during the postremove
    #   phase of packaging during the state of the system defined by pkg_state (either removal or upgrade)
    def get_postremove_actions(pkg_state)
      scripts = components.flat_map(&:postremove_actions).compact.select { |s| s.pkg_state.include? pkg_state }.map(&:scripts)
      if scripts.empty?
        return ': no postremove scripts provided'
      else
        return scripts.join("\n")
      end
    end

    # Collects any configfiles supplied by components
    #
    # @return [Array] array of configfiles installed by components of the project
    def get_configfiles
      components.flat_map(&:configfiles).uniq
    end

    def has_configfiles?
      !get_configfiles.empty?
    end

    # Collects any directories declared by the project and components
    #
    # @return [Array] the directories in the project and components
    def get_directories
      dirs = []
      dirs.push @directories
      dirs.push components.flat_map(&:directories)
      dirs.flatten.uniq
    end

    # Gets the highest level directories declared by the project
    #
    # @return [Array] the highest level directories that have been declared by the project
    def get_root_directories # rubocop:disable Metrics/AbcSize
      dirs = get_directories.map { |dir| dir.path.split('/') }
      dirs.sort! { |dir1, dir2| dir1.length <=> dir2.length }
      ret_dirs = []

      dirs.each do |dir|
        unless ret_dirs.include?(dir.first(dir.length - 1).join('/'))
          ret_dirs << dir.join('/')
        end
      end
      ret_dirs
    end

    # This originally lived in the Makefile.erb template, but it's pretty
    # domain-inspecific and we should try to minimize assignment
    # inside an ERB template
    # @return [Array] all of the paths produced by #get_directories
    def dirnames
      get_directories.map(&:path)
    end

    # Get any services registered by components in the project
    #
    # @return [Array] the services provided by components in the project
    def get_services
      components.flat_map(&:service).compact
    end

    # Simple utility for determining if the components in the project declare
    # any services
    #
    # @return [True, False] Whether or not there are services declared for this project or not
    def has_services?
      !get_services.empty?
    end

    # Generate a list of all files and directories to be included in a tarball
    # for the project
    #
    # @return [Array] all the files and directories that should be included in the tarball
    def get_tarball_files
      files = ['file-list', 'bill-of-materials']
      files.push get_files.map(&:path)
      files.push get_configfiles.map(&:path)
      if @platform.is_windows?
        files.flatten.map { |f| "$(shell cygpath --mixed --long-name '#{f}')" }
      else
        files.flatten
      end
    end

    # Generate a bill-of-materials: a listing of the components and their
    # versions in the current project
    #
    # @return [Array] a listing of component names and versions
    def generate_bill_of_materials
      components.map { |comp| "#{comp.name} #{comp.version}" }.sort
    end

    # Method to generate the command to create a tarball of the project
    #
    # @return [String] cross platform command to generate a tarball of the project
    def pack_tarball_command
      tar_root = "#{@name}-#{@version}"
      ["mkdir -p '#{tar_root}'",
       %('#{@platform.tar}' -cf - -T "#{get_tarball_files.join('" "')}" | ( cd '#{tar_root}/'; '#{@platform.tar}' xfp -)),
       %('#{@platform.tar}' -cf - #{tar_root}/ | gzip -9c > #{tar_root}.tar.gz)].join("\n\t")
    end

    # Evaluates the makefile template and writes the contents to the workdir
    # for use in building the project
    #
    # @param workdir [String] full path to the workdir to send the evaluated template
    # @return [String] full path to the generated Makefile
    def make_makefile(workdir)
      erb_file(File.join(VANAGON_ROOT, "resources/Makefile.erb"), File.join(workdir, "Makefile"))
    end

    # Generates a bill-of-materials and writes the contents to the workdir for use in
    # building the project
    #
    # @param workdir [String] full path to the workdir to send the bill-of-materials
    # @return [String] full path to the generated bill-of-materials
    def make_bill_of_materials(workdir)
      File.open(File.join(workdir, 'bill-of-materials'), 'w') { |f| f.puts(generate_bill_of_materials.join("\n")) }
    end

    # Return a list of the build_dependencies that are satisfied by an internal component
    #
    # @param component [Vanagon::Component] component to check for already satisfied build dependencies
    # @return [Array] a list of the build dependencies for the given component that are satisfied by other components in the project
    def list_component_dependencies(component)
      component.build_requires.select { |dep| components.map(&:name).include?(dep) }
    end

    # Get the package name for the project on the current platform
    #
    # @return [String] package name for the current project as defined by the platform
    def package_name
      @platform.package_name(self)
    end

    # Ascertain how to build a package for the current platform
    #
    # @return [String, Array] commands to build a package for the current project as defined by the platform
    def generate_package
      @platform.generate_package(self)
    end

    # Generate any required files to build a package for this project on the
    # current platform into the provided workdir
    #
    # @param workdir [String] workdir to put the packaging files into
    def generate_packaging_artifacts(workdir)
      @platform.generate_packaging_artifacts(workdir, @name, binding, self)
    end

    # Generate a json hash which lists all of the dependant components of the
    # project.
    #
    # @return [Hash] where the top level keys are components and their values
    #   are hashes with additional information on the component.
    def generate_dependencies_info
      components.each_with_object({}) do |component, hsh|
        hsh.merge!(component.get_dependency_hash)
      end
    end

    # Generate a hash which contains relevant information regarding components
    # of a package, what vanagon built the package, time of build, as well as
    # version of the thing we were building.
    #
    # @return [Hash] of information which is useful to know about how a package
    #   was built and what went into the package.
    def build_manifest_json
      manifest = {
        "packaging_type" => {
          "vanagon" => VANAGON_VERSION,
        },
        "version" => version,
        "components" => generate_dependencies_info,
        "build_time" => BUILD_TIME,
      }
    end

    # Writes a json file at `ext/build_metadata.json` containing information
    # about what went into a built artifact
    #
    # @return [Hash] of build information
    def save_manifest_json
      manifest = build_manifest_json
      File.open(File.join('ext', 'build_metadata.json'), 'w') do |f|
        f.write(JSON.pretty_generate(manifest))
      end
    end
  end
end
