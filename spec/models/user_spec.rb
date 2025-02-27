require 'rails_helper'

describe User do
  it { is_expected.to have_many(:key_pairs).dependent(:destroy) }
  it { is_expected.to validate_presence_of :user_name }
  it { is_expected.to validate_presence_of :last_name }
  it { is_expected.to validate_presence_of :first_name }
  it { is_expected.to validate_presence_of :display_name }
  it { is_expected.to allow_value('AutotestUser').for(:type) }
  it { is_expected.to allow_value('EndUser').for(:type) }
  it { is_expected.not_to allow_value('OtherTypeOfUser').for(:type) }
  it { is_expected.not_to allow_value('A!a.sa').for(:user_name) }
  it { is_expected.to allow_value('Ads_-hb').for(:user_name) }
  it { is_expected.to allow_value('-22125-k1lj42_').for(:user_name) }
  it { is_expected.to validate_inclusion_of(:locale).in_array(I18n.available_locales.map(&:to_s)) }

  describe 'AutotestUser' do
    subject { create :autotest_user }
    it { is_expected.to allow_value('A!a.sa').for(:user_name) }
    it { is_expected.to allow_value('.autotest').for(:user_name) }
  end

  describe 'uniqueness validation' do
    subject { create :end_user }
    it { is_expected.to validate_uniqueness_of :user_name }
  end

  context 'A good User model' do
    it 'should be able to create an end_user user' do
      create(:end_user)
    end
  end

  context 'User creation validations' do
    before :each do
      new_user = { user_name: '   ausername   ',
                   first_name: '   afirstname ',
                   last_name: '   alastname  ' }
      @user = EndUser.new(new_user)
    end

    it 'should strip all strings with white space from user name' do
      expect(@user.save).to eq true
      expect(@user.user_name).to eq 'ausername'
      expect(@user.first_name).to eq 'afirstname'
      expect(@user.last_name).to eq 'alastname'
    end

    it 'should set default display name to be first + last name' do
      expect(@user.save).to eq true
      expect(@user.display_name).to eq "#{@user.first_name} #{@user.last_name}"
    end
  end

  describe '.authenticate' do
    context 'bad character' do
      it 'should not allow a null char in the username' do
        expect(User.authenticate("a\0b", '123')).to eq User::AUTHENTICATE_BAD_CHAR
      end
      it 'should not allow a null char in the password' do
        expect(User.authenticate('ab', "12\0a3")).to eq User::AUTHENTICATE_BAD_CHAR
      end
      it 'should not allow a newline in the username' do
        expect(User.authenticate("a\nb", '123')).to eq User::AUTHENTICATE_BAD_CHAR
      end
      it 'should not allow a newline in the username' do
        expect(User.authenticate('ab', "12\na3")).to eq User::AUTHENTICATE_BAD_CHAR
      end
    end
    context 'bad platform' do
      it 'should not allow validation if the server OS is windows' do
        stub_const('RUBY_PLATFORM', 'mswin')
        expect(User.authenticate('ab', '123')).to eq User::AUTHENTICATE_BAD_PLATFORM
      end
    end
    context 'without a custom exit status messages' do
      context 'a successful login' do
        it 'should return a success message' do
          allow_any_instance_of(Process::Status).to receive(:exitstatus).and_return(0)
          expect(User.authenticate('ab', '123')).to eq User::AUTHENTICATE_SUCCESS
        end
      end
      context 'an unsuccessful login' do
        it 'should return a failure message' do
          allow_any_instance_of(Process::Status).to receive(:exitstatus).and_return(1)
          expect(User.authenticate('ab', '123')).to eq User::AUTHENTICATE_ERROR
        end
      end
    end
    context 'with a custom exit status message' do
      before do
        allow(Settings).to receive(:validate_custom_status_message).and_return('2' => 'a two!', '3' => 'a three!')
      end
      context 'a successful login' do
        it 'should return a success message' do
          allow_any_instance_of(Process::Status).to receive(:exitstatus).and_return(0)
          expect(User.authenticate('ab', '123')).to eq User::AUTHENTICATE_SUCCESS
        end
      end
      context 'an unsuccessful login' do
        it 'should return a failure message with a 1' do
          allow_any_instance_of(Process::Status).to receive(:exitstatus).and_return(1)
          expect(User.authenticate('ab', '123')).to eq User::AUTHENTICATE_ERROR
        end
        it 'should return a failure message with a 4' do
          allow_any_instance_of(Process::Status).to receive(:exitstatus).and_return(4)
          expect(User.authenticate('ab', '123')).to eq User::AUTHENTICATE_ERROR
        end
        it 'should return a custom message with a 2' do
          allow_any_instance_of(Process::Status).to receive(:exitstatus).and_return(2)
          expect(User.authenticate('ab', '123')).to eq '2'
        end
        it 'should return a custom message with a 3' do
          allow_any_instance_of(Process::Status).to receive(:exitstatus).and_return(3)
          expect(User.authenticate('ab', '123')).to eq '3'
        end
      end
    end
  end
end
