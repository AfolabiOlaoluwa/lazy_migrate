# frozen_string_literal: true

require 'tty-prompt'
require 'active_record'
require 'rails'
require "lazy_migrate/migration_adapter_factory"

module LazyMigrate
  class Migrator
    class << self
      MIGRATE = 'migrate'
      ROLLBACK = 'rollback'
      UP = 'up'
      DOWN = 'down'
      REDO = 'redo'
      BRING_TO_TOP = 'bring to top'

      def run
        migration_adapter = MigrationAdapterFactory.create_migration_adapter

        loop do
          catch(:done) do
            on_done = -> { throw :done }

            load_migration_paths
            migrations = find_migrations(migration_adapter)

            prompt = TTY::Prompt.new(active_color: :bright_green)
            prompt.ok("\nDatabase: #{ActiveRecord::Base.connection_config[:database]}\n")

            select_migration_prompt(prompt: prompt, migrations: migrations, on_done: on_done, migration_adapter: migration_adapter)
          end
        end
      rescue TTY::Reader::InputInterrupt
        puts
      end

      private

      def find_migrations(migration_adapter)
        current_version = migration_adapter.last_version

        migration_adapter.find_migration_tuples
          .reverse
          .map { |status, str_version, name|
            # This depends on how rails reports a file is missing.
            # This is no doubt subject to change so be wary.
            has_file = name != '********** NO FILE **********'
            version = str_version.to_i
            current = version == current_version

            {
              status: status,
              version: version,
              name: name,
              has_file: has_file,
              current: current,
            }
          }
      end

      def load_migration_paths
        # silencing cos we might be re-initializing some constants and rails
        # doesn't like that
        Kernel.silence_warnings do
          ActiveRecord::Migrator.migrations_paths.each do |path|
            Dir[Rails.application.root.join("#{path}/**/*.rb")].each { |file| load file }
          end
        end
      end

      def select_migration_prompt(prompt:, migrations:, on_done:, migration_adapter:)
        prompt.select('Pick a migration') do |menu|
          migrations.each { |migration|
            name = render_migration_option(migration)

            menu.choice(
              name,
              -> {
                select_action_prompt(
                  on_done: on_done,
                  prompt: prompt,
                  migration_adapter: migration_adapter,
                  migration: migration,
                )
              }
            )
          }
        end
      end

      def select_action_prompt(on_done:, migration_adapter:, prompt:, migration:)
        if !migration[:has_file]
          prompt.error("\nMigration file not found for migration #{migration[:version]}")
          prompt_any_key(prompt)
          on_done.()
        end

        option_map = obtain_option_map(migration_adapter: migration_adapter)

        prompt.select("\nWhat would you like to do for #{migration[:version]} #{name}?") do |inner_menu|
          options_for_migration(status: migration[:status]).each do |option|
            inner_menu.choice(option, -> {
              with_unsafe_error_capture do
                option_map[option].(migration)
              end
              dump_schema
              prompt_any_key(prompt)
              on_done.()
            })
          end

          inner_menu.choice('cancel', on_done)
        end
      end

      def options_for_migration(status:)
        common_options = [MIGRATE, ROLLBACK, BRING_TO_TOP]
        specific_options = if status == 'up'
          [DOWN, REDO]
        else
          [UP]
        end
        specific_options + common_options
      end

      def obtain_option_map(migration_adapter:)
        {
          UP => ->(migration) { migration_adapter.up(migration) },
          DOWN => ->(migration) { migration_adapter.down(migration) },
          REDO => ->(migration) { migration_adapter.redo(migration) },
          MIGRATE => ->(migration) { migration_adapter.migrate(migration) },
          ROLLBACK => ->(migration) { migration_adapter.rollback(migration) },
          BRING_TO_TOP => ->(migration) { bring_to_top(migration: migration, migration_adapter: migration_adapter) },
        }
      end

      def render_migration_option(migration)
        "#{
          migration[:status].ljust(6)
        }#{
          migration[:version].to_s.ljust(16)
        }#{
          (migration[:current] ? 'current' : '').ljust(9)
        }#{
          migration[:name].ljust(50)
        }"
      end

      # bring_to_top updates the version of a migration to bring it to the top of the
      # migration list. If the migration had already been up'd it will mark the
      # new migration file as upped as well. The former version number will be
      # removed from the schema_migrations table. The user chooses whether
      # they want to down the migration before moving it.
      def bring_to_top(migration:, migration_adapter:)
        initial_status = migration[:status]
        filename = migration_adapter.find_filename_for_migration(migration)

        if filename.nil?
          raise("No file found for migration #{migration[:version]}")
        end

        re_run = initial_status == 'up' &&
                 prompt.yes?('Migration has been run. Would you like to `down` the migration before moving it, and then run it again after?')

        if re_run
          migration_adapter.down(migration)
        end

        last = migration_adapter.last_version
        new_version = ActiveRecord::Migration.next_migration_number(last ? last + 1 : 0)
        new_filename = replace_version_in_filename(filename, new_version)
        File.rename(filename, new_filename)

        if initial_status == 'up'
          if re_run
            migration_adapter.up({ status: 'down', version: new_version, filename: new_filename })
          else
            ActiveRecord::SchemaMigration.create(version: new_version)
            ActiveRecord::SchemaMigration.find_by(version: migration[:version])&.destroy!
          end
        end
      end

      def replace_version_in_filename(filename, new_version)
        basename = File.basename(filename)
        dir = File.dirname(filename)
        new_basename = "#{new_version}_#{basename.split('_')[1..].join('_')}"
        File.join(dir, new_basename)
      end

      def prompt_any_key(prompt)
        prompt.keypress("\nPress any key to continue")
      end

      def with_unsafe_error_capture
        yield
      rescue Exception => e # rubocop:disable Lint/RescueException
        # I am aware you should not rescue 'Exception' exceptions but I think this is is an 'exceptional' use case
        puts "\n#{e.class}: #{e.message}\n#{e.backtrace.take(5).join("\n")}"
      end

      def dump_schema
        return if !ActiveRecord::Base.dump_schema_after_migration

        # ripped from https://github.com/rails/rails/blob/5-1-stable/activerecord/lib/active_record/railties/databases.rake
        filename = ENV["SCHEMA"] || File.join(ActiveRecord::Tasks::DatabaseTasks.db_dir, "schema.rb")
        File.open(filename, "w:utf-8") do |file|
          ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, file)
        end
      end
    end
  end

  def self.run
    Migrator.show
  end
end
