require 'rails_helper'

RSpec.describe Terranet::Branding do
  let(:terranet) { described_class.terranet_values }
  let(:upstream) { described_class.upstream_values }
  let(:backup_dir) { Dir.mktmpdir('terranet-branding') }
  let(:backup) { Pathname.new(backup_dir).join('branding_backup.json') }

  def stored(key)
    InstallationConfig.find_by(name: key)&.value
  end

  around do |example|
    with_modified_env(TERRANET_BRANDING_BACKUP: backup.to_s) do
      described_class.reset_to_upstream_defaults
      backup.delete if backup.exist?
      example.run
    ensure
      FileUtils.remove_entry(backup_dir)
    end
  end

  describe '.apply' do
    it 'writes every whitelisted key with the Terranet values' do
      described_class.apply

      expect(terranet.keys.index_with { |key| stored(key) }).to eq(terranet)
    end

    it 'is idempotent: a second run reports no changes and keeps the same rows' do
      described_class.apply
      ids = InstallationConfig.where(name: terranet.keys).pluck(:id).sort

      expect(described_class.apply).to eq({})
      expect(InstallationConfig.where(name: terranet.keys).pluck(:id).sort).to eq(ids)
    end

    it 'does not write anything on a dry run but reports the pending changes' do
      changes = described_class.apply(dry_run: true)

      expect(changes.keys).to match_array(terranet.keys)
      expect(stored('INSTALLATION_NAME')).to eq(upstream['INSTALLATION_NAME'])
    end

    it 'leaves unrelated installation configs untouched' do
      InstallationConfig.create!(name: 'ENABLE_ACCOUNT_SIGNUP', value: 'false')

      expect { described_class.apply }.not_to(change { InstallationConfig.find_by(name: 'ENABLE_ACCOUNT_SIGNUP').attributes })
    end

    it 'refuses keys outside the whitelist' do
      allow(YAML).to receive(:safe_load_file).with(described_class::TERRANET_FILE).and_return('INSTALLATION_NAME' => 'X',
                                                                                              'CAPTAIN_OPEN_AI_API_KEY' => 'k')

      expect { described_class.terranet_values }.to raise_error(ArgumentError, /CAPTAIN_OPEN_AI_API_KEY/)
    end
  end

  describe 'layout', type: :request do
    it 'serves the Terranet name, logos and theme color on the login page' do
      InstallationConfig.find_or_initialize_by(name: 'DISPLAY_MANIFEST').tap { |config| config.value = true }.save!
      described_class.apply
      get '/app/login'

      expect(response.body).to include('Terranet', '/brand-assets/terranet/logo.png', '/brand-assets/terranet/logo_dark.png',
                                       '/brand-assets/terranet/logo_thumbnail.png', '#2D2DBA')
    end

    it 'brands the Super Admin sign-in page and keeps the Chatwoot engine/version visible in the console' do
      described_class.apply
      get '/super_admin/sign_in'

      expect(response.body).to include('SuperAdmin | Terranet', '/brand-assets/terranet/logo.png', '/brand-assets/terranet/logo_dark.png')

      sign_in(create(:super_admin), scope: :super_admin)
      get '/super_admin'

      expect(response.body).to include('/brand-assets/terranet/logo_thumbnail.png', "Chatwoot v#{Chatwoot.config[:version]}", '- Terranet</title>')
    end

    it 'keeps upstream names and logos in Super Admin until the branding is applied' do
      get '/super_admin/sign_in'

      expect(response.body).to include('SuperAdmin | Chatwoot', '/brand-assets/logo.svg')
    end
  end

  describe '.reset_to_upstream_defaults' do
    it 'overwrites the branding keys with upstream defaults' do
      described_class.apply
      described_class.reset_to_upstream_defaults

      expect(upstream.keys.index_with { |key| stored(key) }).to eq(upstream)
    end
  end

  describe 'snapshot and .restore_previous' do
    let(:customised) { { 'INSTALLATION_NAME' => 'Acme Support', 'LOGO' => '/acme/logo.svg' } }

    before { customised.each { |key, value| InstallationConfig.find_by!(name: key).update!(value: value) } }

    def stored_state
      Terranet::Branding::KEYS.index_with { |key| InstallationConfig.find_by(name: key)&.value }
    end

    it 'restores the exact customised values, not upstream defaults' do
      before_state = stored_state
      described_class.apply
      described_class.restore_previous

      expect(stored_state).to eq(before_state)
      expect(stored('INSTALLATION_NAME')).to eq('Acme Support')
    end

    it 'removes keys that did not exist before apply and recreates the ones that did' do
      InstallationConfig.find_by!(name: 'BRAND_URL').destroy!
      before_state = stored_state
      described_class.apply
      expect(stored('BRAND_URL')).to eq(terranet['BRAND_URL'])

      described_class.restore_previous

      expect(stored_state).to eq(before_state)
      expect(InstallationConfig.exists?(name: 'BRAND_URL')).to be(false)
    end

    it 'keeps the ORIGINAL snapshot across repeated applies and an upstream reset' do
      before_state = stored_state
      described_class.apply
      described_class.reset_to_upstream_defaults
      described_class.apply
      described_class.restore_previous

      expect(stored_state).to eq(before_state)
    end

    it 'writes the snapshot with owner-only permissions and no secrets beyond the 7 whitelisted keys' do
      described_class.apply

      expect(backup.stat.mode & 0o777).to eq(0o600)
      expect(JSON.parse(backup.read)['keys'].keys).to match_array(Terranet::Branding::KEYS)
    end

    it 'does not write or snapshot anything on a dry run' do
      described_class.apply(dry_run: true)

      expect(backup).not_to exist
      expect(stored('INSTALLATION_NAME')).to eq('Acme Support')
    end

    it 'previews a restore without writing and keeps the snapshot' do
      described_class.apply
      changes = described_class.restore_previous(dry_run: true)

      expect(changes['INSTALLATION_NAME']).to eq(['Terranet', 'Acme Support'])
      expect(stored('INSTALLATION_NAME')).to eq('Terranet')
      expect(backup).to exist
    end

    it 'archives the snapshot after a restore so the next apply snapshots the then-current state' do
      described_class.apply
      described_class.restore_previous

      expect(backup).not_to exist
      expect(Dir.children(backup_dir)).to include(a_string_matching(/branding_backup\.restored-\d{8}T\d{6}Z\.json/))
    end

    it 'refuses to restore without a snapshot instead of guessing upstream values' do
      expect { described_class.restore_previous }.to raise_error(Terranet::Branding::NoBackupError, /reset_to_upstream_defaults/)
      expect(stored('INSTALLATION_NAME')).to eq('Acme Support')
    end

    it 'rejects a tampered snapshot (foreign key, missing key, malformed entry)' do
      described_class.apply
      good = JSON.parse(backup.read)

      [good.deep_merge('keys' => { 'CAPTAIN_OPEN_AI_API_KEY' => { 'present' => true, 'value' => 'x' } }),
       { 'keys' => good['keys'].except('LOGO') },
       good.deep_merge('keys' => { 'LOGO' => { 'present' => 'yes' } })].each do |tampered|
        backup.write(JSON.generate(tampered))
        expect { described_class.restore_previous }.to raise_error(ArgumentError)
      end
    end

    it 'is all-or-nothing: a failure in the middle of apply rolls back every key and leaves no snapshot' do
      before_state = stored_state
      calls = 0
      allow(described_class).to receive(:write_value).and_wrap_original do |original, *args|
        calls += 1
        raise ActiveRecord::RecordInvalid if calls == 3

        original.call(*args)
      end

      expect { described_class.apply }.to raise_error(ActiveRecord::RecordInvalid)
      expect(stored_state).to eq(before_state)
      expect(backup).not_to exist
    end

    it 'is all-or-nothing on restore as well' do
      described_class.apply
      applied = stored_state
      calls = 0
      allow(described_class).to receive(:write_value).and_wrap_original do |original, *args|
        calls += 1
        raise ActiveRecord::RecordInvalid if calls == 2

        original.call(*args)
      end

      expect { described_class.restore_previous }.to raise_error(ActiveRecord::RecordInvalid)
      expect(stored_state).to eq(applied)
      expect(backup).to exist
    end
  end

  describe 'brand assets' do
    def png_size(path)
      header = File.binread(path, 24)
      expect(header[0, 8]).to eq("\x89PNG\r\n\x1a\n".b)
      header[16, 8].unpack('NN')
    end

    it 'ships every file referenced by the Terranet values' do
      terranet.values.grep(%r{\A/brand-assets/}).each do |path|
        expect(Rails.public_path.join(path.delete_prefix('/'))).to exist
      end
    end

    it 'ships the thumbnail as a 512x512 PNG (favicon and sidebar mark)' do
      expect(png_size(Rails.public_path.join('brand-assets/terranet/logo_thumbnail.png'))).to eq([512, 512])
    end

    it 'keeps the aspect ratio of the original glyphs (746x207 bounding box, within 2 percent)' do
      width, height = png_size(Rails.public_path.join('brand-assets/terranet/logo.png'))

      expect((width.to_f / height) / (746.0 / 207)).to be_within(0.02).of(1.0)
    end

    it 'ships every icon the manifest and layout reference, none of them empty' do
      manifest = JSON.parse(Rails.public_path.join('manifest.json').read)
      extra = %w[/favicon-16x16.png /favicon-32x32.png /favicon-96x96.png /favicon-512x512.png /apple-icon-180x180.png
                 /favicon-badge-16x16.png /favicon-badge-32x32.png /favicon-badge-96x96.png /ms-icon-144x144.png]
      icons = manifest['icons'].pluck('src') + extra

      expect(manifest).to include('name' => 'Terranet', 'short_name' => 'Terranet')
      icons.each { |src| expect(Rails.public_path.join(src.delete_prefix('/')).size).to be_positive }
    end
  end
end
