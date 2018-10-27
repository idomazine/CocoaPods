require 'active_support/core_ext/string/inflections'
require 'cocoapods/target/framework_paths'

module Pod
  class Installer
    class UserProjectIntegrator
      # This class is responsible for integrating the library generated by a
      # {TargetDefinition} with its destination project.
      #
      class TargetIntegrator
        autoload :XCConfigIntegrator, 'cocoapods/installer/user_project_integrator/target_integrator/xcconfig_integrator'

        # @return [String] the string to use as prefix for every build phase added to the user project
        #
        BUILD_PHASE_PREFIX = '[CP] '.freeze

        # @return [String] the string to use as prefix for every build phase declared by the user within a podfile
        #         or podspec.
        #
        USER_BUILD_PHASE_PREFIX = '[CP-User] '.freeze

        # @return [String] the name of the check manifest phase
        #
        CHECK_MANIFEST_PHASE_NAME = 'Check Pods Manifest.lock'.freeze

        # @return [Array<Symbol>] the symbol types, which require that the pod
        # frameworks are embedded in the output directory / product bundle.
        #
        # @note This does not include :app_extension or :watch_extension because
        # these types must have their frameworks embedded in their host targets.
        # For messages extensions, this only applies if it's embedded in a messages
        # application.
        #
        EMBED_FRAMEWORK_TARGET_TYPES = [:application, :unit_test_bundle, :ui_test_bundle, :watch2_extension, :messages_application].freeze

        # @return [String] the name of the embed frameworks phase
        #
        EMBED_FRAMEWORK_PHASE_NAME = 'Embed Pods Frameworks'.freeze

        # @return [String] the name of the copy resources phase
        #
        COPY_PODS_RESOURCES_PHASE_NAME = 'Copy Pods Resources'.freeze

        # @return [Integer] the maximum number of input and output paths to use for a script phase
        #
        MAX_INPUT_OUTPUT_PATHS = 1000

        # @return [AggregateTarget] the target that should be integrated.
        #
        attr_reader :target

        # @return [Boolean] whether to use input/output paths for build phase scripts
        #
        attr_reader :use_input_output_paths
        alias use_input_output_paths? use_input_output_paths

        # Init a new TargetIntegrator
        #
        # @param  [AggregateTarget] target @see #target
        # @param  [Boolean] use_input_output_paths @see #use_input_output_paths
        #
        def initialize(target, use_input_output_paths: true)
          @target = target
          @use_input_output_paths = use_input_output_paths
        end

        class << self
          # Adds a shell script build phase responsible to copy (embed) the frameworks
          # generated by the TargetDefinition to the bundle of the product of the
          # targets.
          #
          # @param [PBXNativeTarget] native_target
          #        The native target to add the script phase into.
          #
          # @param [String] script_path
          #        The script path to execute as part of this script phase.
          #
          # @param [Array<String>] input_paths
          #        The input paths (if any) to include for this script phase.
          #
          # @param [Array<String>] output_paths
          #        The output paths (if any) to include for this script phase.
          #
          # @return [void]
          #
          def create_or_update_embed_frameworks_script_phase_to_target(native_target, script_path, input_paths = [], output_paths = [])
            phase = TargetIntegrator.create_or_update_build_phase(native_target, BUILD_PHASE_PREFIX + EMBED_FRAMEWORK_PHASE_NAME)
            phase.shell_script = %("#{script_path}"\n)
            phase.input_paths = input_paths
            phase.output_paths = output_paths
          end

          # Delete a 'Embed Pods Frameworks' Copy Files Build Phase if present
          #
          # @param [PBXNativeTarget] native_target
          #        The native target to remove the script phase from.
          #
          def remove_embed_frameworks_script_phase_from_target(native_target)
            embed_build_phase = native_target.shell_script_build_phases.find { |bp| bp.name && bp.name.end_with?(EMBED_FRAMEWORK_PHASE_NAME) }
            return unless embed_build_phase.present?
            native_target.build_phases.delete(embed_build_phase)
          end

          # Adds a shell script build phase responsible to copy the resources
          # generated by the TargetDefinition to the bundle of the product of the
          # targets.
          #
          # @param [PBXNativeTarget] native_target
          #        The native target to add the script phase into.
          #
          # @param [String] script_path
          #        The script path to execute as part of this script phase.
          #
          # @param [Array<String>] input_paths
          #        The input paths (if any) to include for this script phase.
          #
          # @param [Array<String>] output_paths
          #        The output paths (if any) to include for this script phase.
          #
          # @return [void]
          #
          def create_or_update_copy_resources_script_phase_to_target(native_target, script_path, input_paths = [], output_paths = [])
            phase_name = COPY_PODS_RESOURCES_PHASE_NAME
            phase = TargetIntegrator.create_or_update_build_phase(native_target, BUILD_PHASE_PREFIX + phase_name)
            phase.shell_script = %("#{script_path}"\n)
            phase.input_paths = input_paths
            phase.output_paths = output_paths
          end

          # Delete a 'Copy Pods Resources' script phase if present
          #
          # @param [PBXNativeTarget] native_target
          #        The native target to remove the script phase from.
          #
          def remove_copy_resources_script_phase_from_target(native_target)
            build_phase = native_target.shell_script_build_phases.find { |bp| bp.name && bp.name.end_with?(COPY_PODS_RESOURCES_PHASE_NAME) }
            return unless build_phase.present?
            native_target.build_phases.delete(build_phase)
          end

          # Creates or update a shell script build phase for the given target.
          #
          # @param [PBXNativeTarget] native_target
          #        The native target to add the script phase into.
          #
          # @param [String] phase_name
          #        The name of the phase to use.
          #
          # @param [Class] phase_class
          #        The class of the phase to use.
          #
          # @return [void]
          #
          def create_or_update_build_phase(native_target, phase_name, phase_class = Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
            build_phases = native_target.build_phases.grep(phase_class)
            build_phases.find { |phase| phase.name && phase.name.end_with?(phase_name) }.tap { |p| p.name = phase_name if p } ||
              native_target.project.new(phase_class).tap do |phase|
                UI.message("Adding Build Phase '#{phase_name}' to project.") do
                  phase.name = phase_name
                  phase.show_env_vars_in_log = '0'
                  native_target.build_phases << phase
                end
              end
          end

          # Updates all target script phases for the current target, including creating or updating, deleting
          # and re-ordering.
          #
          # @return [void]
          #
          def create_or_update_user_script_phases(script_phases, native_target)
            script_phase_names = script_phases.map { |k| k[:name] }
            # Delete script phases no longer present in the target.
            native_target_script_phases = native_target.shell_script_build_phases.select { |bp| !bp.name.nil? && bp.name.start_with?(USER_BUILD_PHASE_PREFIX) }
            native_target_script_phases.each do |script_phase|
              script_phase_name_without_prefix = script_phase.name.sub(USER_BUILD_PHASE_PREFIX, '')
              unless script_phase_names.include?(script_phase_name_without_prefix)
                native_target.build_phases.delete(script_phase)
              end
            end
            # Create or update the ones that are expected to be.
            script_phases.each do |script_phase|
              name_with_prefix = USER_BUILD_PHASE_PREFIX + script_phase[:name]
              phase = TargetIntegrator.create_or_update_build_phase(native_target, name_with_prefix)
              phase.shell_script = script_phase[:script]
              phase.shell_path = script_phase[:shell_path] if script_phase.key?(:shell_path)
              phase.input_paths = script_phase[:input_files] if script_phase.key?(:input_files)
              phase.output_paths = script_phase[:output_files] if script_phase.key?(:output_files)
              phase.show_env_vars_in_log = script_phase[:show_env_vars_in_log] ? '1' : '0' if script_phase.key?(:show_env_vars_in_log)

              execution_position = script_phase[:execution_position]
              unless execution_position == :any
                compile_build_phase_index = native_target.build_phases.index do |bp|
                  bp.is_a?(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
                end
                unless compile_build_phase_index.nil?
                  script_phase_index = native_target.build_phases.index do |bp|
                    bp.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) && !bp.name.nil? && bp.name == name_with_prefix
                  end
                  if (execution_position == :before_compile && script_phase_index > compile_build_phase_index) ||
                    (execution_position == :after_compile && script_phase_index < compile_build_phase_index)
                    native_target.build_phases.move_from(script_phase_index, compile_build_phase_index)
                  end
                end
              end
            end
          end

          # Script phases can have a limited number of input and output paths due to each one being exported to `env`.
          # A large number can cause a build failure because of limitations in `env`. See issue
          # https://github.com/CocoaPods/CocoaPods/issues/7362.
          #
          # @param [Array<String>] input_paths
          #        The input paths to trim.
          #
          # @param [Array<String>] output_paths
          #        The output paths to trim.
          #
          # @return [void]
          #
          def validate_input_output_path_limit(input_paths, output_paths)
            if (input_paths.count + output_paths.count) > MAX_INPUT_OUTPUT_PATHS
              input_paths.clear
              output_paths.clear
            end
          end

          # Returns an extension in the target that corresponds to the
          # resource's input extension.
          #
          # @param [String] input_extension
          #        The input extension to map to.
          #
          # @return [String] The output extension.
          #
          def output_extension_for_resource(input_extension)
            case input_extension
            when '.storyboard'        then '.storyboardc'
            when '.xib'               then '.nib'
            when '.framework'         then '.framework'
            when '.xcdatamodel'       then '.mom'
            when '.xcdatamodeld'      then '.momd'
            when '.xcmappingmodel'    then '.cdm'
            when '.xcassets'          then '.car'
            else                      input_extension
            end
          end

          # Returns the resource output paths for all given input paths.
          #
          # @param [Array<String>] resource_input_paths
          #        The input paths to map to.
          #
          # @return [Array<String>] The resource output paths.
          #
          def resource_output_paths(resource_input_paths)
            resource_input_paths.map do |resource_input_path|
              base_path = '${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}'
              extname = File.extname(resource_input_path)
              basename = extname == '.xcassets' ? 'Assets' : File.basename(resource_input_path)
              output_extension = TargetIntegrator.output_extension_for_resource(extname)
              File.join(base_path, File.basename(basename, extname) + output_extension)
            end.uniq
          end

          # Returns the framework output paths for the given input paths
          #
          # @param  [Array<Target::FrameworkPaths>] framework_input_paths
          #         The framework input paths to map to output paths.
          #
          # @return [Array<String>] The framework output paths
          #
          def framework_output_paths(framework_input_paths)
            framework_input_paths.flat_map do |framework_path|
              framework_output_path = "${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/#{File.basename(framework_path.source_path)}"
              dsym_path = if (dsym_input_path = framework_path.dsym_path)
                            "${DWARF_DSYM_FOLDER_PATH}/#{File.basename(dsym_input_path)}"
                          end
              [framework_output_path, dsym_path]
            end.compact.uniq
          end
        end

        # Integrates the user project targets. Only the targets that do **not**
        # already have the Pods library in their frameworks build phase are
        # processed.
        #
        # @return [void]
        #
        def integrate!
          UI.section(integration_message) do
            XCConfigIntegrator.integrate(target, native_targets)

            add_pods_library
            add_embed_frameworks_script_phase
            remove_embed_frameworks_script_phase_from_embedded_targets
            add_copy_resources_script_phase
            add_check_manifest_lock_script_phase
            add_user_script_phases
          end
        end

        # @return [String] a string representation suitable for debugging.
        #
        def inspect
          "#<#{self.class} for target `#{target.label}'>"
        end

        private

        # @!group Integration steps
        #---------------------------------------------------------------------#

        # Adds spec product reference to the frameworks build phase of the
        # {TargetDefinition} integration libraries. Adds a file reference to
        # the frameworks group of the project and adds it to the frameworks
        # build phase of the targets.
        #
        # @return [void]
        #
        def add_pods_library
          frameworks = user_project.frameworks_group
          native_targets.each do |native_target|
            build_phase = native_target.frameworks_build_phase

            # Find and delete possible reference for the other product type
            old_product_name = target.build_as_framework? ? target.static_library_name : target.framework_name
            old_product_ref = frameworks.files.find { |f| f.path == old_product_name }
            if old_product_ref.present?
              UI.message("Removing old Pod product reference #{old_product_name} from project.")
              build_phase.remove_file_reference(old_product_ref)
              frameworks.remove_reference(old_product_ref)
            end

            # Find or create and add a reference for the current product type
            target_basename = target.product_basename
            new_product_ref = frameworks.files.find { |f| f.path == target.product_name } ||
              frameworks.new_product_ref_for_target(target_basename, target.product_type)
            build_phase.build_file(new_product_ref) ||
              build_phase.add_file_reference(new_product_ref, true)
          end
        end

        # Find or create a 'Copy Pods Resources' build phase
        #
        # @return [void]
        #
        def add_copy_resources_script_phase
          unless target.includes_resources?
            native_targets.each do |native_target|
              TargetIntegrator.remove_copy_resources_script_phase_from_target(native_target)
            end
            return
          end
          script_path = target.copy_resources_script_relative_path
          input_paths = []
          output_paths = []
          if use_input_output_paths?
            resource_paths_by_config = target.resource_paths_by_config
            resource_paths_flattened = resource_paths_by_config.values.flatten.uniq
            input_paths = [target.copy_resources_script_relative_path, *resource_paths_flattened]
            output_paths = TargetIntegrator.resource_output_paths(resource_paths_flattened)
          end
          TargetIntegrator.validate_input_output_path_limit(input_paths, output_paths)
          native_targets.each do |native_target|
            # Static library targets cannot include resources. Skip this phase from being added instead.
            next if native_target.symbol_type == :static_library
            TargetIntegrator.create_or_update_copy_resources_script_phase_to_target(native_target, script_path, input_paths, output_paths)
          end
        end

        # Removes the embed frameworks build phase from embedded targets
        #
        # @note Older versions of CocoaPods would add this build phase to embedded
        #       targets. They should be removed on upgrade because embedded targets
        #       will have their frameworks embedded in their host targets.
        #
        def remove_embed_frameworks_script_phase_from_embedded_targets
          return unless target.requires_host_target?
          native_targets.each do |native_target|
            if AggregateTarget::EMBED_FRAMEWORKS_IN_HOST_TARGET_TYPES.include? native_target.symbol_type
              TargetIntegrator.remove_embed_frameworks_script_phase_from_target(native_target)
            end
          end
        end

        # Find or create a 'Embed Pods Frameworks' Copy Files Build Phase
        #
        # @return [void]
        #
        def add_embed_frameworks_script_phase
          unless target.includes_frameworks?
            native_targets_to_embed_in.each do |native_target|
              TargetIntegrator.remove_embed_frameworks_script_phase_from_target(native_target)
            end
            return
          end
          script_path = target.embed_frameworks_script_relative_path
          input_paths = []
          output_paths = []
          if use_input_output_paths?
            framework_paths = target.framework_paths_by_config.values.flatten.uniq
            framework_input_paths = framework_paths.flat_map { |path| [path.source_path, path.dsym_path] }.compact
            input_paths = [target.embed_frameworks_script_relative_path, *framework_input_paths]
            output_paths = TargetIntegrator.framework_output_paths(framework_paths)
            TargetIntegrator.validate_input_output_path_limit(input_paths, output_paths)
          end

          native_targets_to_embed_in.each do |native_target|
            TargetIntegrator.create_or_update_embed_frameworks_script_phase_to_target(native_target, script_path, input_paths, output_paths)
          end
        end

        # Updates all target script phases for the current target, including creating or updating, deleting
        # and re-ordering.
        #
        # @return [void]
        #
        def add_user_script_phases
          native_targets.each do |native_target|
            TargetIntegrator.create_or_update_user_script_phases(target.target_definition.script_phases, native_target)
          end
        end

        # Adds a shell script build phase responsible for checking if the Pods
        # locked in the Pods/Manifest.lock file are in sync with the Pods defined
        # in the Podfile.lock.
        #
        # @note   The build phase is appended to the front because to fail
        #         fast.
        #
        # @return [void]
        #
        def add_check_manifest_lock_script_phase
          phase_name = CHECK_MANIFEST_PHASE_NAME
          native_targets.each do |native_target|
            phase = TargetIntegrator.create_or_update_build_phase(native_target, BUILD_PHASE_PREFIX + phase_name)
            native_target.build_phases.unshift(phase).uniq! unless native_target.build_phases.first == phase
            phase.shell_script = <<-SH.strip_heredoc
              diff "${PODS_PODFILE_DIR_PATH}/Podfile.lock" "${PODS_ROOT}/Manifest.lock" > /dev/null
              if [ $? != 0 ] ; then
                  # print error to STDERR
                  echo "error: The sandbox is not in sync with the Podfile.lock. Run 'pod install' or update your CocoaPods installation." >&2
                  exit 1
              fi
              # This output is used by Xcode 'outputs' to avoid re-running this script phase.
              echo "SUCCESS" > "${SCRIPT_OUTPUT_FILE_0}"
            SH
            phase.input_paths = %w(${PODS_PODFILE_DIR_PATH}/Podfile.lock ${PODS_ROOT}/Manifest.lock)
            phase.output_paths = [target.check_manifest_lock_script_output_file_path]
          end
        end

        private

        # @!group Private Helpers
        #---------------------------------------------------------------------#

        # @return [Array<PBXNativeTarget>] The list of all the targets that
        #         match the given target.
        #
        def native_targets
          @native_targets ||= target.user_targets
        end

        # @return [Array<PBXNativeTarget>] The list of all the targets that
        #         require that the pod frameworks are embedded in the output
        #         directory / product bundle.
        #
        def native_targets_to_embed_in
          return [] if target.requires_host_target?
          native_targets.select do |target|
            EMBED_FRAMEWORK_TARGET_TYPES.include?(target.symbol_type)
          end
        end

        # Read the project from the disk to ensure that it is up to date as
        # other TargetIntegrators might have modified it.
        #
        # @return [Project]
        #
        def user_project
          target.user_project
        end

        # @return [Specification::Consumer] the consumer for the specifications.
        #
        def spec_consumers
          @spec_consumers ||= target.pod_targets.map(&:file_accessors).flatten.map(&:spec_consumer)
        end

        # @return [String] the message that should be displayed for the target
        #         integration.
        #
        def integration_message
          "Integrating target `#{target.name}` " \
            "(#{UI.path target.user_project_path} project)"
        end
      end
    end
  end
end
