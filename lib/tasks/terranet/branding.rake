# rubocop:disable Metrics/BlockLength
namespace :terranet do
  namespace :branding do
    def terranet_branding_report(changes, dry_run)
      puts(dry_run ? 'DRY RUN (nothing written):' : 'Done:')
      changes.each { |key, (old, new)| puts "  #{key}: #{old.inspect} -> #{new.inspect}" }
      puts '  (no changes)' if changes.empty?
    end

    desc 'Apply Terranet branding (idempotent, whitelisted keys). Snapshots the previous state first. DRY_RUN=1 to preview'
    task apply: :environment do
      dry_run = ENV['DRY_RUN'].present?
      terranet_branding_report(Terranet::Branding.apply(dry_run: dry_run), dry_run)
      puts "  snapshot: #{Terranet::Branding.backup_file}" if !dry_run && Terranet::Branding.backup_file.exist?
    end

    desc 'Restore EXACTLY what the installation had before the first managed apply (from the snapshot). DRY_RUN=1 to preview'
    task restore: :environment do
      dry_run = ENV['DRY_RUN'].present?
      terranet_branding_report(Terranet::Branding.restore_previous(dry_run: dry_run), dry_run)
    rescue Terranet::Branding::NoBackupError => e
      abort "ERROR: #{e.message}"
    end

    desc 'Overwrite the branding keys with upstream defaults (config/installation_config.yml), NOT the previous state. DRY_RUN=1'
    task reset_to_upstream_defaults: :environment do
      dry_run = ENV['DRY_RUN'].present?
      terranet_branding_report(Terranet::Branding.reset_to_upstream_defaults(dry_run: dry_run), dry_run)
    end

    desc 'Show current vs desired branding values and snapshot presence'
    task status: :environment do
      Terranet::Branding.status.each do |key, v|
        puts "#{v[:current] == v[:desired] ? 'OK  ' : 'DIFF'} #{key}: #{v[:current].inspect} (desired #{v[:desired].inspect})"
      end
      puts "snapshot: #{Terranet::Branding.backup_file.exist? ? Terranet::Branding.backup_file : 'none'}"
    end
  end
end
# rubocop:enable Metrics/BlockLength
