namespace :terranet do
  namespace :branding do
    def terranet_branding_report(changes, dry_run)
      puts(dry_run ? 'DRY RUN (nothing written):' : 'Applied:')
      changes.each { |key, (old, new)| puts "  #{key}: #{old.inspect} -> #{new.inspect}" }
      puts '  (no changes, already up to date)' if changes.empty?
    end

    desc 'Apply Terranet branding to installation_configs (idempotent, whitelisted keys only). DRY_RUN=1 to preview'
    task apply: :environment do
      dry_run = ENV['DRY_RUN'].present?
      terranet_branding_report(Terranet::Branding.apply(dry_run: dry_run), dry_run)
    end

    desc 'Restore the upstream default values for the branding keys. DRY_RUN=1 to preview'
    task revert: :environment do
      dry_run = ENV['DRY_RUN'].present?
      terranet_branding_report(Terranet::Branding.revert(dry_run: dry_run), dry_run)
    end

    desc 'Show current vs desired branding values'
    task status: :environment do
      Terranet::Branding.status.each do |key, v|
        puts "#{v[:current] == v[:desired] ? 'OK  ' : 'DIFF'} #{key}: #{v[:current].inspect} (desired #{v[:desired].inspect})"
      end
    end
  end
end
