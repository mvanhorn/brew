# typed: strict
# frozen_string_literal: true

require "bundle/extensions/extension"

module Homebrew
  module Bundle
    class MacAppStore < Extension
      PACKAGE_TYPE = :mas
      PACKAGE_TYPE_NAME = "App"
      BANNER_NAME = "Mac App Store dependencies"

      class << self
        sig { override.params(name: String, options: Homebrew::Bundle::Extension::EntryOptions).returns(Dsl::Entry) }
        def entry(name, options = {})
          unknown_options = options.keys - [:id]
          raise "unknown options(#{unknown_options.inspect}) for mas" if unknown_options.present?

          id = options[:id]
          raise "options[:id](#{id}) should be an Integer object" unless id.is_a? Integer

          Dsl::Entry.new(:mas, name, id:)
        end

        sig { override.returns(T::Boolean) }
        def add_supported?
          false
        end

        sig { override.void }
        def reset!
          @apps = T.let(nil, T.nilable(T::Array[[String, String]]))
          @installed_packages = T.let(nil, T.nilable(T::Array[Integer]))
          @outdated_app_ids = T.let(nil, T.nilable(T::Array[Integer]))
        end

        sig { returns(T::Array[[String, String]]) }
        def apps
          apps = @apps
          return apps if apps

          @apps = if Bundle.mas_installed?
            mas = Bundle.which_mas
            return [] if mas.nil?

            `#{mas} list 2>/dev/null`.split("\n").filter_map do |app|
              app_details = app.match(/\A\s*(?<id>\d+)\s+(?<name>.*?)\s+\((?<version>[\d.]*)\)\Z/)

              # Only add the application details should we have a valid match.
              # Strip unprintable characters
              if app_details
                name = app_details[:name]
                id = app_details[:id]
                next if name.nil? || id.nil?

                [id, name.gsub(/[[:cntrl:]]|\p{C}/, "")]
              end
            end
          else
            []
          end
        end

        sig { override.returns(T::Array[[String, String]]) }
        def packages
          apps
        end

        sig { returns(T::Array[Integer]) }
        def app_ids
          apps.map { |id, _| id.to_i }
        end

        sig { override.params(name: String, options: Homebrew::Bundle::Extension::EntryOptions).returns(Object) }
        def package_record_for(name, options = {})
          { name:, id: T.cast(options.fetch(:id), Integer) }
        end

        sig { override.params(package: Object).returns(String) }
        def dump_entry(package)
          "mas #{quote(package_name(package))}, id: #{package_id_string(package)}"
        end

        sig { override.returns(String) }
        def dump
          apps.sort_by { |_, name| name.downcase }.map { |app| dump_entry(app) }.join("\n")
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
          id = T.cast(options.fetch(:id), Integer)

          unless Bundle.mas_installed?
            puts "Installing mas. It is not currently installed." if verbose
            Bundle.brew("install", "mas", verbose:)
            raise "Unable to install #{name} app. mas installation failed." unless Bundle.mas_installed?
          end

          if app_id_installed?(id) &&
             (no_upgrade || !app_id_upgradable?(id))
            puts "Skipping install of #{name} app. It is already installed." if verbose
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

          id = T.cast(options.fetch(:id), Integer)

          return true unless preinstall

          mas = Bundle.which_mas
          return false if mas.nil?

          if app_id_installed?(id)
            puts "Upgrading #{name} app. It is installed but not up-to-date." if verbose
            return Bundle.system(mas, "upgrade", id.to_s, verbose:)
          end

          puts "Installing #{name} app. It is not currently installed." if verbose
          return false unless Bundle.system(mas, "get", id.to_s, verbose:)

          installed_packages << id
          true
        end

        sig {
          params(
            name:       String,
            id:         T.nilable(Integer),
            no_upgrade: T::Boolean,
            verbose:    T::Boolean,
            options:    Homebrew::Bundle::Extension::EntryOptions,
          ).returns(T::Boolean).checked(:never)
        }
        def preinstall!(name, id = nil, no_upgrade: false, verbose: false, **options)
          preinstall_with_options!(
            name,
            id ? { id: } : options,
            no_upgrade:,
            verbose:,
          )
        end

        sig {
          params(
            name:       String,
            id:         T.nilable(Integer),
            preinstall: T::Boolean,
            no_upgrade: T::Boolean,
            verbose:    T::Boolean,
            force:      T::Boolean,
            options:    Homebrew::Bundle::Extension::EntryOptions,
          ).returns(T::Boolean).checked(:never)
        }
        def install!(name, id = nil, preinstall: true, no_upgrade: false, verbose: false, force: false, **options)
          install_with_options!(
            name,
            id ? { id: } : options,
            preinstall:,
            no_upgrade:,
            verbose:,
            force:,
          )
        end

        sig { params(id: Integer, no_upgrade: T::Boolean).returns(T::Boolean) }
        def app_id_installed_and_up_to_date?(id, no_upgrade: false)
          return false unless app_id_installed?(id)
          return true if no_upgrade

          !app_id_upgradable?(id)
        end

        sig { params(id: Integer).returns(T::Boolean) }
        def app_id_installed?(id)
          installed_app_ids.include? id
        end

        sig { params(id: Integer).returns(T::Boolean) }
        def app_id_upgradable?(id)
          outdated_app_ids.include? id
        end

        sig { returns(T::Array[Integer]) }
        def installed_app_ids
          installed_app_ids = @installed_packages
          return installed_app_ids if installed_app_ids

          @installed_packages = app_ids
        end

        sig { override.returns(T::Array[Integer]) }
        def installed_packages
          installed_app_ids
        end

        sig { returns(T::Array[Integer]) }
        def outdated_app_ids
          outdated_app_ids = @outdated_app_ids
          return outdated_app_ids if outdated_app_ids

          @outdated_app_ids = if Bundle.mas_installed?
            mas = Bundle.which_mas
            return [] if mas.nil?

            `#{mas} outdated 2>/dev/null`.split("\n").map do |app|
              app.split(" ", 2).first.to_i
            end
          else
            []
          end
        end

        sig { params(package: Object).returns(String) }
        def package_name(package)
          case package
          when Hash
            name = package[:name]
            return name if name.is_a?(String)
          when Array
            name = package[1]
            return name.to_s if name
          end

          package.to_s
        end

        sig { params(package: Object).returns(String) }
        def package_id_string(package)
          case package
          when Hash
            id = package[:id]
            return id.to_s if id.is_a?(Integer)
          when Array
            id = package[0]
            return id.to_s if id
          when Integer
            return package.to_s
          end

          package.to_s
        end
        private :package_id_string

        sig { params(package: Object).returns(Integer) }
        def package_id(package)
          case package
          when Hash
            id = package[:id]
            return id if id.is_a?(Integer)
          when Array
            id = package[0]
            return id if id.is_a?(Integer)
            return id.to_i if id.is_a?(String)
          when Integer
            return package
          end

          raise "package(#{package.inspect}) should contain an app id"
        end

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

      sig { override.params(package: Object, no_upgrade: T::Boolean).returns(String) }
      def failure_reason(package, no_upgrade:)
        reason = if no_upgrade
          "needs to be installed."
        else
          "needs to be installed or updated."
        end

        "#{self.class.check_label} #{self.class.package_name(package)} #{reason}"
      end

      sig { override.params(package: Object, no_upgrade: T::Boolean).returns(T::Boolean) }
      def installed_and_up_to_date?(package, no_upgrade: false)
        self.class.app_id_installed_and_up_to_date?(self.class.package_id(package), no_upgrade:)
      end
    end

    # TODO: Remove these compatibility aliases once bundle callers and tests
    # stop requiring separate mac_app_store dumper/installer/checker constants.
    MacAppStoreDumper = MacAppStore
    MacAppStoreInstaller = MacAppStore

    module Checker
      # TODO: Remove this compatibility alias once bundle callers and tests stop
      # requiring a separate mac_app_store checker constant.
      MacAppStoreChecker = Homebrew::Bundle::MacAppStore
    end
  end
end
