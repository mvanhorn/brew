# typed: strict
# frozen_string_literal: true

require "bundle/extensions/extension"

module Homebrew
  module Bundle
    class Flatpak < Extension
      PACKAGE_TYPE = :flatpak
      PACKAGE_TYPE_NAME = "Flatpak"
      BANNER_NAME = "Flatpak packages"

      class << self
        sig { override.params(name: String, options: Homebrew::Bundle::Extension::EntryOptions).returns(Dsl::Entry) }
        def entry(name, options = {})
          unknown_options = options.keys - [:remote, :url]
          raise "unknown options(#{unknown_options.inspect}) for flatpak" if unknown_options.present?

          remote = options[:remote]
          url = options[:url]

          # Validate: url: can only be used with a named remote (not a URL remote)
          if url.present? && remote.is_a?(String) && remote.start_with?("http://", "https://")
            raise "url: parameter cannot be used when remote: is already a URL"
          end

          normalized_options = options.dup

          # Default remote to "flathub"
          normalized_options[:remote] ||= "flathub"

          Dsl::Entry.new(:flatpak, name, normalized_options)
        end

        sig { override.returns(T.nilable(String)) }
        def cleanup_heading
          "flatpaks"
        end

        sig { override.void }
        def reset!
          @packages = T.let(nil, T.nilable(T::Array[String]))
          @packages_with_remotes = T.let(nil, T.nilable(T::Array[T::Hash[Symbol, T.nilable(String)]]))
          @remote_urls = T.let(nil, T.nilable(T::Hash[String, String]))
        end

        sig { returns(T::Hash[String, String]) }
        def remote_urls
          remote_urls = @remote_urls
          return remote_urls if remote_urls

          @remote_urls = if Bundle.flatpak_installed?
            flatpak = Bundle.which_flatpak
            return {} if flatpak.nil?

            output = `#{flatpak} remote-list --system --columns=name,url 2>/dev/null`.chomp
            output.split("\n").each_with_object({}) do |line, urls|
              parts = line.strip.split("\t")
              next if parts.size < 2

              name = parts[0]
              url = parts[1]
              urls[name] = url if name && url
            end
          else
            {}
          end
        end

        sig { returns(T::Array[T::Hash[Symbol, T.nilable(String)]]) }
        def packages_with_remotes
          packages_with_remotes = @packages_with_remotes
          return packages_with_remotes if packages_with_remotes

          @packages_with_remotes = if Bundle.flatpak_installed?
            flatpak = Bundle.which_flatpak
            return [] if flatpak.nil?

            # List applications with their origin remote
            # Using --app to filter applications only
            # Using --columns=application,origin to get app IDs and their remotes
            output = `#{flatpak} list --app --columns=application,origin 2>/dev/null`.chomp
            urls = remote_urls # Get the URL mapping

            output.split("\n").filter_map do |line|
              parts = line.strip.split("\t")
              name = parts[0]
              next if parts.empty? || name.nil? || name.empty?

              remote = parts[1] || "flathub"
              { name:, remote:, remote_url: urls[remote] }
            end.sort_by { |package| package[:name].to_s }
          else
            []
          end
        end

        sig { override.returns(T::Array[String]) }
        def packages
          packages = @packages
          return packages if packages

          @packages = packages_with_remotes.map { |package| package[:name].to_s }
        end

        sig { override.returns(T::Array[T::Hash[Symbol, T.nilable(String)]]) }
        def installed_packages
          packages_with_remotes
        end

        sig { override.params(name: String, options: Homebrew::Bundle::Extension::EntryOptions).returns(Object) }
        def package_record_for(name, options = {})
          {
            name:   name,
            remote: remote_from_options(options),
            url:    url_from_options(options),
          }
        end

        sig { override.params(package: Object).returns(String) }
        def dump_name(package)
          package_name(package)
        end

        sig { override.params(package: Object).returns(Homebrew::Bundle::Extension::EntryOptions) }
        def dump_options(package)
          remote = package_remote(package)
          remote_url = package_remote_url(package)

          # 3-tier remote handling for dump:
          # - Tier 1: flathub → no remote needed
          # - Tier 2: single-app remote (*-origin) → dump with URL only
          # - Tier 3: named shared remote → dump with remote: and url:
          if remote == "flathub"
            # Tier 1: Don't specify remote for flathub (default)
            {}
          elsif remote.end_with?("-origin")
            # Tier 2: Single-app remote - dump with URL only
            if remote_url.present?
              { remote: remote_url }
            else
              # Fallback if URL not available (shouldn't happen for -origin remotes)
              { remote: remote }
            end
          elsif remote_url.present?
            # Tier 3: Named shared remote - dump with name and URL
            { remote:, url: remote_url }
          else
            # Named remote without URL (user-defined or system remote)
            { remote: }
          end
        end

        sig { override.returns(String) }
        def dump
          packages_with_remotes.map { |package| dump_entry(package) }.join("\n")
        end

        sig { override.params(name: String, options: Homebrew::Bundle::Extension::EntryOptions).returns(T::Boolean) }
        def package_installed_for?(name, options = {})
          remote = remote_from_options(options)
          url = url_from_options(options)

          if url.nil? && remote.start_with?("http://", "https://")
            # Tier 2: URL only - resolve to single-app remote name
            # (.flatpakref - check by name only since remote name varies)
            return installed_packages.any? { |installed| installed[:name] == name } if remote.end_with?(".flatpakref")

            return installed_packages.any? do |installed|
              installed[:name] == name && installed[:remote] == generate_single_app_remote_name(name)
            end
          end

          installed_packages.any? do |installed|
            installed[:name] == name && installed[:remote] == remote
          end
        end

        sig {
          override.params(
            name:       String,
            options:    Homebrew::Bundle::Extension::EntryOptions,
            no_upgrade: T::Boolean,
            verbose:    T::Boolean,
          ).returns(T::Boolean)
        }
        def preinstall_with_options!(name, options = {}, no_upgrade: false, verbose: false)
          _ = no_upgrade
          _ = options

          return false unless Bundle.flatpak_installed?

          # Check if package is installed at all (regardless of remote)
          if installed_packages.any? { |installed| installed[:name] == name }
            puts "Skipping install of #{name} Flatpak. It is already installed." if verbose
            return false
          end

          true
        end

        sig {
          override.params(
            name:       String,
            options:    Homebrew::Bundle::Extension::EntryOptions,
            preinstall: T::Boolean,
            no_upgrade: T::Boolean,
            verbose:    T::Boolean,
            force:      T::Boolean,
          ).returns(T::Boolean)
        }
        def install_with_options!(name, options = {}, preinstall: true, no_upgrade: false, verbose: false,
                                  force: false)
          _ = no_upgrade
          _ = force

          return true unless Bundle.flatpak_installed?
          return true unless preinstall

          flatpak = Bundle.which_flatpak
          return false if flatpak.nil?

          remote = remote_from_options(options)
          url = url_from_options(options)

          # 3-tier remote handling:
          # - Tier 1: no URL → use named remote (default: flathub)
          # - Tier 2: URL only → single-app remote (<app-id>-origin)
          # - Tier 3: URL + name → named shared remote

          if url.present?
            # Tier 3: Named remote with URL - create shared remote
            puts "Installing #{name} Flatpak from #{remote} (#{url}). It is not currently installed." if verbose
            ensure_named_remote_exists!(flatpak.to_s, remote, url, verbose:)
            actual_remote = remote
          elsif remote.start_with?("http://", "https://")
            if remote.end_with?(".flatpakref")
              # .flatpakref files - install directly (Flatpak handles single-app remote natively)
              puts "Installing #{name} Flatpak from #{remote}. It is not currently installed." if verbose
              return install_flatpakref!(flatpak.to_s, name, remote, verbose:)
            end

            # Tier 2: URL only - create single-app remote
            actual_remote = generate_single_app_remote_name(name)
            if verbose
              puts "Installing #{name} Flatpak from #{actual_remote} (#{remote}). It is not currently installed."
            end
            ensure_single_app_remote_exists!(flatpak.to_s, actual_remote, remote, verbose:)
          else
            # Tier 1: Named remote (default: flathub)
            puts "Installing #{name} Flatpak from #{remote}. It is not currently installed." if verbose
            actual_remote = remote
          end

          return false unless Bundle.system(flatpak.to_s, "install", "-y", "--system", actual_remote, name, verbose:)

          installed_packages << { name:, remote: actual_remote, remote_url: url }
          true
        end

        # Install from a .flatpakref file (Tier 2 variant - Flatpak handles single-app remote natively)
        sig { params(flatpak: String, name: String, url: String, verbose: T::Boolean).returns(T::Boolean) }
        def install_flatpakref!(flatpak, name, url, verbose:)
          return false unless Bundle.system(flatpak, "install", "-y", "--system", url, verbose:)

          # Get the actual remote name used by Flatpak
          output = `#{flatpak} list --app --columns=application,origin 2>/dev/null`.chomp
          installed = output.split("\n").find { |line| line.start_with?(name) }
          actual_remote = installed ? installed.split("\t")[1] : "#{name}-origin"
          installed_packages << { name:, remote: actual_remote, remote_url: url }
          true
        end

        # Generate a single-app remote name (Tier 2)
        # Pattern: <app-id>-origin (matches Flatpak's native behavior for .flatpakref)
        sig { params(app_id: String).returns(String) }
        def generate_single_app_remote_name(app_id)
          "#{app_id}-origin"
        end

        # Ensure a single-app remote exists (Tier 2)
        # Safe to replace if URL differs since it's isolated per-app
        sig { params(flatpak: String, remote_name: String, url: String, verbose: T::Boolean).void }
        def ensure_single_app_remote_exists!(flatpak, remote_name, url, verbose:)
          existing_url = get_remote_url(flatpak, remote_name)

          if existing_url && existing_url != url
            # Single-app remote with different URL - safe to replace
            puts "Replacing single-app remote #{remote_name} (URL changed)" if verbose
            Bundle.system(flatpak, "remote-delete", "--system", "--force", remote_name, verbose:)
            existing_url = nil
          end

          return if existing_url # Already exists with correct URL

          puts "Adding single-app remote #{remote_name} from #{url}" if verbose
          add_remote!(flatpak, remote_name, url, verbose:)
        end

        # Ensure a named shared remote exists (Tier 3)
        # Warn but don't change if URL differs (user explicitly named it)
        sig { params(flatpak: String, remote_name: String, url: String, verbose: T::Boolean).void }
        def ensure_named_remote_exists!(flatpak, remote_name, url, verbose:)
          existing_url = get_remote_url(flatpak, remote_name)

          if existing_url && existing_url != url
            # Named remote with different URL - warn but don't change (user explicitly named it)
            puts "Warning: Remote '#{remote_name}' exists with different URL (#{existing_url}), using existing"
            return
          end

          return if existing_url # Already exists with correct URL

          puts "Adding named remote #{remote_name} from #{url}" if verbose
          add_remote!(flatpak, remote_name, url, verbose:)
        end

        # Get URL for an existing remote, or nil if not found
        sig { params(flatpak: String, remote_name: String).returns(T.nilable(String)) }
        def get_remote_url(flatpak, remote_name)
          output = `#{flatpak} remote-list --system --columns=name,url 2>/dev/null`.chomp
          output.split("\n").each do |line|
            parts = line.split("\t")
            return parts[1] if parts[0] == remote_name
          end

          nil
        end

        # Add a remote with appropriate flags
        sig { params(flatpak: String, remote_name: String, url: String, verbose: T::Boolean).returns(T::Boolean) }
        def add_remote!(flatpak, remote_name, url, verbose:)
          if url.end_with?(".flatpakrepo")
            Bundle.system(flatpak, "remote-add", "--if-not-exists", "--system", remote_name, url, verbose:)
          else
            # For bare repository URLs, add with --no-gpg-verify for user repos
            Bundle.system(flatpak, "remote-add", "--if-not-exists", "--system",
                          "--no-gpg-verify", remote_name, url, verbose:)
          end
        end

        sig { override.params(package: Object).returns(Homebrew::Bundle::Extension::EntryOptions) }
        def package_options(package)
          options = {}
          options[:remote] = package_remote(package)
          remote_url = package_url(package)
          options[:url] = remote_url if remote_url.present?
          options
        end

        sig { override.params(entries: T::Array[Object]).returns(T::Array[String]) }
        def cleanup_items(entries)
          return [].freeze unless Bundle.flatpak_installed?

          require "bundle/skipper"
          kept_flatpaks = entries.filter_map do |entry|
            entry = T.cast(entry, Dsl::Entry)
            next if entry.type != :flatpak
            next if Bundle::Skipper.skip?(entry)

            entry.name
          end

          # To provide a graceful migration from `Brewfile`s that don't yet or
          # don't want to use `flatpak`: don't remove any flatpaks if we don't
          # find any in the `Brewfile`.
          return [].freeze if kept_flatpaks.empty?

          packages - kept_flatpaks
        end

        sig { params(package: Object).returns(String) }
        def package_name(package)
          return package[:name].to_s if package.is_a?(Hash)

          package.to_s
        end
        private :package_name

        sig { params(package: Object).returns(String) }
        def package_remote(package)
          if package.is_a?(Hash)
            if package.key?(:options)
              options = package[:options]
              if options.is_a?(Hash)
                remote = options[:remote]
                return remote if remote.is_a?(String) && remote.present?
              end
            end

            remote = package[:remote]
            return remote if remote.is_a?(String) && remote.present?
          end

          "flathub"
        end
        private :package_remote

        sig { params(package: Object).returns(T.nilable(String)) }
        def package_url(package)
          return nil unless package.is_a?(Hash)

          if package.key?(:options)
            options = package[:options]
            if options.is_a?(Hash)
              url = options[:url]
              return url if url.is_a?(String)
            end
          end

          url = package[:url]
          return url if url.is_a?(String)

          nil
        end
        private :package_url

        sig { params(package: Object).returns(T.nilable(String)) }
        def package_remote_url(package)
          return nil unless package.is_a?(Hash)

          remote_url = package[:remote_url]
          return remote_url if remote_url.is_a?(String)

          nil
        end
        private :package_remote_url

        sig { params(options: Homebrew::Bundle::Extension::EntryOptions).returns(String) }
        def remote_from_options(options)
          remote = options[:remote]
          return remote if remote.is_a?(String) && !remote.empty?

          "flathub"
        end
        private :remote_from_options

        sig { params(options: Homebrew::Bundle::Extension::EntryOptions).returns(T.nilable(String)) }
        def url_from_options(options)
          url = options[:url]
          return url if url.is_a?(String)

          nil
        end
        private :url_from_options

        sig {
          override.params(
            name:    String,
            options: Homebrew::Bundle::Extension::EntryOptions,
            verbose: T::Boolean,
          ).returns(T::Boolean)
        }
        def install_package_with_options!(name, options = {}, verbose: false)
          _ = name
          _ = verbose
          _ = options

          false
        end
      end
    end

    # TODO: Remove these compatibility aliases once bundle callers and tests
    # stop requiring separate flatpak dumper/installer/checker constants.
    FlatpakDumper = Flatpak
    FlatpakInstaller = Flatpak

    module Checker
      # TODO: Remove this compatibility alias once bundle callers and tests stop
      # requiring a separate flatpak checker constant.
      FlatpakChecker = Homebrew::Bundle::Flatpak
    end
  end
end
