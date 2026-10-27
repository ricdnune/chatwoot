require 'rails_helper'

# Upgrade tripwire: fails when a new Chatwoot-operated endpoint or a new caller of ChatwootHub appears in the
# source after an upstream merge, so it gets reviewed in docs/terranet/03-privacy-egress-audit.md.
RSpec.describe Terranet::Privacy do
  describe 'Chatwoot endpoint regression guard' do
    let(:root) { Rails.root }

    # file => reviewed purpose; keep in sync with docs/terranet/03-privacy-egress-audit.md
    let(:known_chatwoot_hub_files) do
      %w[
        lib/chatwoot_hub.rb
        lib/terranet/chatwoot_hub_privacy.rb
      ]
    end

    let(:known_chatwoot_hub_callers) do
      {
        'app/controllers/installation/onboarding_controller.rb' => 'register_instance',
        'app/jobs/internal/check_new_versions_job.rb' => 'sync_with_hub',
        'app/services/notification/push_notification_service.rb' => 'send_push',
        'app/services/notification/push_test_service.rb' => 'send_push_with_response'
      }
    end

    def ruby_files
      Dir.glob(root.join('{app,lib,config}/**/*.{rb,erb}')).reject { |f| f.include?('/lib/terranet/') }
    end

    it 'has no unreviewed callers of ChatwootHub network methods' do
      hub_methods = /ChatwootHub\.(sync_with_hub|register_instance|send_push|send_push_with_response|emit_event)\b/
      callers = ruby_files.filter_map do |file|
        relative = Pathname.new(file).relative_path_from(root).to_s
        next if known_chatwoot_hub_files.include?(relative)

        relative if File.read(file).match?(hub_methods)
      end

      expect(callers.sort).to eq(known_chatwoot_hub_callers.keys.sort)
    end

    it 'has no unreviewed Chatwoot-operated hosts in frontend request constants' do
      pattern = /(hub\.2\.chatwoot\.com|testimonials\.cdn\.chatwoot\.com|[a-z0-9-]+\.cdn\.chatwoot\.com)/
      files = Dir.glob(root.join('app/javascript/**/*.{js,vue}')).reject { |f| f.include?('/i18n/') || f.match?(/spec|story|fixtures/) }
      hits = files.filter_map do |file|
        relative = Pathname.new(file).relative_path_from(root).to_s
        relative if File.read(file).match?(pattern)
      end

      expect(hits.sort).to eq(%w[app/javascript/dashboard/constants/globals.js app/javascript/shared/constants/links.js])
    end

    it 'keeps the Ruby-side hub base URL as the only hard-coded hub host' do
      hits = ruby_files.filter_map do |file|
        relative = Pathname.new(file).relative_path_from(root).to_s
        relative if File.read(file).include?('hub.2.chatwoot.com')
      end

      expect(hits).to eq(['lib/chatwoot_hub.rb'])
    end
  end
end
