# typed: strict
# frozen_string_literal: true

require "bundle/extensions/extension"

module Homebrew
  module Bundle
    class Cargo < Extension
      PACKAGE_TYPE = :cargo
      PACKAGE_TYPE_NAME = "Cargo Package"
      BANNER_NAME = "Cargo packages"

      class << self
        sig { override.params(name: String, options: Homebrew::Bundle::Extension::EntryOptions).returns(Dsl::Entry) }
        def entry(name, options = {})
          raise "unknown options(#{options.keys.inspect}) for cargo" if options.present?

          Dsl::Entry.new(:cargo, name)
        end

        sig { override.returns(String) }
        def package_manager_name
          "rust"
        end

        sig { override.void }
        def reset!
          @packages = T.let(nil, T.nilable(T::Array[String]))
          @installed_packages = T.let(nil, T.nilable(T::Array[String]))
        end

        sig { override.returns(T::Array[String]) }
        def packages
          packages = @packages
          return packages if packages

          @packages = if Bundle.cargo_installed?
            cargo = Bundle.which_cargo
            return [] if cargo.nil?

            parse_package_list(`#{cargo} install --list`)
          else
            []
          end
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

          cargo = package_manager_executable
          return false if cargo.nil?

          with_env("PATH" => "#{cargo.dirname}:#{ENV.fetch("PATH")}") do
            Bundle.system(cargo.to_s, "install", "--locked", name, verbose:)
          end
        end

        sig { override.returns(T::Array[String]) }
        def installed_packages
          installed_packages = @installed_packages
          return installed_packages if installed_packages

          @installed_packages = packages.dup
        end

        sig { params(output: String).returns(T::Array[String]) }
        def parse_package_list(output)
          output.lines.filter_map do |line|
            next if line.match?(/^\s/)

            match = line.match(/\A(?<name>[^\s:]+)\s+v[0-9A-Za-z.+-]+/)
            match[:name] if match
          end.uniq
        end
        private :parse_package_list
      end
    end

    # TODO: Remove these compatibility aliases once bundle callers and tests
    # stop requiring separate cargo dumper/installer/checker constants.
    CargoDumper = Cargo
    CargoInstaller = Cargo

    module Checker
      # TODO: Remove this compatibility alias once bundle callers and tests stop
      # requiring a separate cargo checker constant.
      CargoChecker = Homebrew::Bundle::Cargo
    end
  end
end
