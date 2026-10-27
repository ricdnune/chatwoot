namespace :terranet do
  namespace :isp do
    desc 'Create SYNTHETIC identity candidates (fake contacts and fake service ids) for the lab. Mock mode only, idempotent'
    task seed_synthetic: :environment do
      abort 'refused: Terranet ISP is not in mock mode' unless Terranet::Isp.mode == :mock
      abort 'refused: never seed synthetic data in production' if Rails.env.production?

      samples = [['Synthetic Subscriber One', 'DEMO-0001', 'demo-onu-0001', 'sn_onu'],
                 ['Synthetic Subscriber Two', 'DEMO-0002', 'demo-onu-0002', 'sn_onu'],
                 ['Synthetic Subscriber Three', 'DEMO-0003', nil, 'manual']]
      Account.find_each do |account|
        samples.each_with_index do |(name, service, onu, matched_by), index|
          contact = Contact.find_or_create_by!(account_id: account.id, identifier: "terranet-synthetic-#{index + 1}") { |c| c.name = name }
          Terranet::Isp::Binding.find_or_create_by!(account_id: account.id, contact_id: contact.id, wisphub_service_id: service) do |binding_record|
            binding_record.smartolt_external_id = onu
            binding_record.matched_by = matched_by
          end
        end
      end
      puts "Synthetic candidates present: #{Terranet::Isp::Binding.count}"
    end
  end
end
