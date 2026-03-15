# typed: strict
# frozen_string_literal: true

require "bundle/extensions/extension"

module Homebrew
  module Bundle
    class VscodeExtension < Extension
      PACKAGE_TYPE = :vscode
      PACKAGE_TYPE_NAME = "VSCode Extension"
      BANNER_NAME = "VSCode (and forks/variants) extensions"

      class << self
        sig { override.params(name: String, options: Homebrew::Bundle::Extension::EntryOptions).returns(Dsl::Entry) }
        def entry(name, options = {})
          raise "unknown options(#{options.keys.inspect}) for vscode" if options.present?

          Dsl::Entry.new(:vscode, name)
        end

        sig { override.returns(T.nilable(String)) }
        def cleanup_heading
          "VSCode extensions"
        end

        sig { override.void }
        def reset!
          @packages = T.let(nil, T.nilable(T::Array[String]))
          @installed_packages = T.let(nil, T.nilable(T::Array[String]))
        end

        sig { returns(T::Array[String]) }
        def extensions
          packages
        end

        sig { override.returns(T::Array[String]) }
        def packages
          packages = @packages
          return packages if packages

          @packages = if Bundle.vscode_installed?
            vscode = Bundle.which_vscode
            return [] if vscode.nil?

            Bundle.exchange_uid_if_needed! do
              ENV["WSL_DISTRO_NAME"] = ENV.fetch("HOMEBREW_WSL_DISTRO_NAME", nil)
              `"#{vscode}" --list-extensions 2>/dev/null`
            end.split("\n").map(&:downcase)
          else
            []
          end
        end

        sig { override.params(name: String, options: Homebrew::Bundle::Extension::EntryOptions).returns(Object) }
        def package_record_for(name, options = {})
          _ = options

          name.downcase
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

          if !Bundle.vscode_installed? && Bundle.cask_installed?
            puts "Installing visual-studio-code. It is not currently installed." if verbose
            Bundle.brew("install", "--cask", "visual-studio-code", verbose:)
          end

          if package_installed?(name)
            puts "Skipping install of #{name} VSCode extension. It is already installed." if verbose
            return false
          end

          raise "Unable to install #{name} VSCode extension. VSCode is not installed." unless Bundle.vscode_installed?

          true
        end

        sig {
          override.params(
            name:    String,
            options: Homebrew::Bundle::Extension::EntryOptions,
            verbose: T::Boolean,
          ).returns(T::Boolean)
        }
        def install_package_with_options!(name, options = {}, verbose: false)
          _ = options

          vscode = package_manager_executable
          return false if vscode.nil?

          Bundle.exchange_uid_if_needed! do
            Bundle.system(vscode, "--install-extension", name, verbose:)
          end
        end

        sig { params(name: String).returns(T::Boolean) }
        def extension_installed?(name)
          installed_extensions.include?(package_record(name))
        end

        sig { override.params(name: String, options: Homebrew::Bundle::Extension::EntryOptions).returns(T::Boolean) }
        def package_installed_for?(name, options = {})
          _ = options

          extension_installed?(name)
        end

        sig { returns(T::Array[String]) }
        def installed_extensions
          installed_extensions = @installed_packages
          return installed_extensions if installed_extensions

          @installed_packages = packages.dup
        end

        sig { override.returns(T::Array[String]) }
        def installed_packages
          installed_extensions
        end

        sig { override.params(entries: T::Array[Object]).returns(T::Array[String]) }
        def cleanup_items(entries)
          require "bundle/skipper"
          kept_extensions = entries.filter_map do |entry|
            entry = T.cast(entry, Dsl::Entry)
            next if entry.type != :vscode
            next if Bundle::Skipper.skip?(entry)

            package_record(entry.name)
          end

          # To provide a graceful migration from `Brewfile`s that don't yet or
          # don't want to use `vscode`: don't remove any extensions if we don't
          # find any in the `Brewfile`.
          return [].freeze if kept_extensions.empty?

          extensions - kept_extensions
        end
      end
    end

    # TODO: Remove these compatibility aliases once bundle callers and tests
    # stop requiring separate vscode dumper/installer/checker constants.
    VscodeExtensionDumper = VscodeExtension
    VscodeExtensionInstaller = VscodeExtension

    module Checker
      # TODO: Remove this compatibility alias once bundle callers and tests stop
      # requiring a separate vscode checker constant.
      VscodeExtensionChecker = Homebrew::Bundle::VscodeExtension
    end
  end
end
