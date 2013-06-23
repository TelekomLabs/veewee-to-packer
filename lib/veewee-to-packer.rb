require "fileutils"
require "json"
require "pathname"

require "veewee-to-packer/builders/vmware"
require "veewee-to-packer/error"
require "veewee-to-packer/mock_veewee"
require "veewee-to-packer/version"

module VeeweeToPacker
  BUILDERS = {
    "vmware" => Builders::VMware
  }

  # Converts the given Veewee template into a Packer template, outputting
  # the JSON to the given output path. The builders that the template will
  # contain is specified by `builders`.
  def self.convert(input, output, builders)
    builders = builders.map do |builder|
      klass = BUILDERS[builder.downcase]
      raise Error, "No such builder: #{builder}" if !klass
      klass
    end

    # Make the output directory
    output = Pathname.new(output)
    output.mkpath

    # Determine the directory where the template is
    input_dir = Pathname.new(input).parent

    # Load the definition file and capture its configuration
    begin
      load input
    rescue LoadError => e
      raise Error, "Error loading input template: #{e}"
    end

    definition = Veewee::Definition.captured

    # This will keep track of any warnings (errors are raised) that
    # we have during the conversion process.
    warnings = []

    # This will be the packer template contents that we'll turn to JSON
    template = {}

    # First, convert the postinstall_files into a shell provisioning step
    if definition[:postinstall_files]
      provisioner = { "type" => "shell" }
      provisioner["scripts"] = definition.delete(:postinstall_files).map do |script|
        scripts_dir = output.join("scripts")
        scripts_dir.mkpath

        script_file_src = Pathname.new(File.expand_path(script, input_dir))
        script_file_dest = scripts_dir.join(script_file_src.basename)

        FileUtils.cp(script_file_src, script_file_dest)

        "scripts/#{script_file_dest.basename}"
      end

      template["provisioners"] = [provisioner]

      # Unused fields
      if definition[:postinstall_timeout]
        definition.delete(:postinstall_timeout)
        warnings << "':postinstall_timeout' doesn't exist in Packer."
      end
    end

    template["builders"] = builders.map do |builder|
      config, build_warnings = builder.convert(definition.dup, input_dir, output)
      if build_warnings && !build_warnings.empty?
        build_warnings.each do |warning|
          warnings << "Builder '#{builder.name}': #{warning}"
        end
      end

      config
    end

    output.join("template.json").open("w") do |f|
      f.write(JSON.pretty_generate(template))
    end

    warnings
  end
end
