require 'rails_helper'

RSpec.describe Terranet::Branding do
  let(:terranet) { described_class.terranet_values }
  let(:upstream) { described_class.upstream_values }

  def stored(key)
    InstallationConfig.find_by(name: key)&.value
  end

  before { described_class.revert }

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

  describe '.revert' do
    it 'restores upstream defaults for the branding keys only' do
      described_class.apply
      described_class.revert

      expect(upstream.keys.index_with { |key| stored(key) }).to eq(upstream)
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
