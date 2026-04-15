require 'spec_helper'

describe 'server_capabilities' do
  describe '#capabilities' do
    it 'should return a hash' do
      expect(PuppetLanguageServer::ServerCapabilities.capabilities).to be_a(Hash)
    end
  end
end
