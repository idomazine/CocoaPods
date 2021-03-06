module Pod
  class Installer
    # Cleans up the sandbox directory by removing stale target support files and headers.
    #
    class SandboxDirCleaner
      # @return [Sandbox] The sandbox directory that will be cleaned.
      #
      attr_reader :sandbox

      # @return [Array<PodTarget>]
      #         The list of all pod targets that will be installed into the Sandbox.
      #
      attr_reader :pod_targets

      # @return [Array<AggregateTarget>]
      #         The list of all aggregate targets that will be installed into the Sandbox.
      #
      attr_reader :aggregate_targets

      # Initialize a new instance
      #
      # @param [Sandbox] sandbox @see #sandbox
      # @param [Array<PodTarget>] pod_targets @see #pod_targets
      # @param [Array<AggregateTarget>] aggregate_targets @see #aggregate_targets
      #
      def initialize(sandbox, pod_targets, aggregate_targets)
        @sandbox = sandbox
        @pod_targets = pod_targets
        @aggregate_targets = aggregate_targets
      end

      def clean!
        UI.message('Cleaning up sandbox directory') do
          # Clean up Target Support Files Directory
          target_support_dirs_to_install = (pod_targets + aggregate_targets).map(&:support_files_dir)
          target_support_dirs = sandbox_target_support_dirs

          removed_target_support_dirs = target_support_dirs - target_support_dirs_to_install
          removed_target_support_dirs.each { |dir| remove_dir(dir) }

          # Clean up Sandbox Headers Directory
          sandbox_private_headers_to_install = pod_targets.flat_map do |pod_target|
            if pod_target.header_mappings_by_file_accessor.empty?
              []
            else
              [pod_target.build_headers.root.join(pod_target.headers_sandbox)]
            end
          end
          sandbox_public_headers_to_install = pod_targets.flat_map do |pod_target|
            if pod_target.public_header_mappings_by_file_accessor.empty?
              []
            else
              [sandbox.public_headers.root.join(pod_target.headers_sandbox)]
            end
          end

          removed_sandbox_public_headers = sandbox_public_headers - sandbox_public_headers_to_install
          removed_sandbox_public_headers.each { |path| remove_dir(path) }

          removed_sandbox_private_headers = sandbox_private_headers(pod_targets) - sandbox_private_headers_to_install
          removed_sandbox_private_headers.each { |path| remove_dir(path) }
        end
      end

      private

      def sandbox_target_support_dirs
        child_directories_of(sandbox.target_support_files_root)
      end

      def sandbox_private_headers(pod_targets)
        pod_targets.flat_map { |pod_target| child_directories_of(pod_target.build_headers.root) }.uniq
      end

      def sandbox_public_headers
        child_directories_of(sandbox.public_headers.root)
      end

      def child_directories_of(dir)
        return [] unless dir.exist?
        dir.children.select(&:directory?)
      end

      def remove_dir(path)
        FileUtils.rm_rf(path)
      end
    end
  end
end
