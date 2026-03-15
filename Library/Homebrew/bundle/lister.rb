# typed: strict
# frozen_string_literal: true

require "bundle/extensions"

module Homebrew
  module Bundle
    module Lister
      sig {
        params(entries: T::Array[Object], formulae: T::Boolean, casks: T::Boolean, taps: T::Boolean,
               mas: T::Boolean, vscode: T::Boolean, cargo: T::Boolean, flatpak: T::Boolean,
               extension_types: T::Boolean).void
      }
      def self.list(entries, formulae:, casks:, taps:, mas:, vscode:, cargo:, flatpak:, **extension_types)
        extension_types = T.let(
          { mas:, vscode:, cargo:, flatpak:, **extension_types },
          Homebrew::Bundle::ExtensionTypes,
        )
        entries.each do |entry|
          entry = T.cast(entry, Dsl::Entry)
          puts entry.name if show?(entry.type, formulae:, casks:, taps:, **extension_types)
        end
      end

      sig {
        params(type: Symbol, formulae: T::Boolean, casks: T::Boolean, taps: T::Boolean, extension_types: T::Boolean)
          .returns(T::Boolean)
      }
      private_class_method def self.show?(type, formulae:, casks:, taps:, **extension_types)
        extension_types = T.let(extension_types, Homebrew::Bundle::ExtensionTypes)
        return true if formulae && type == :brew
        return true if casks && type == :cask
        return true if taps && type == :tap
        return true if extension_types.fetch(type, false)

        false
      end
    end
  end
end
