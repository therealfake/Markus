describe AnnotationCategoryPolicy do
  let(:context) { { role: role, real_user: role.human } }
  describe_rule :manage? do
    succeed 'when the role is an admin' do
      let(:role) { build(:admin) }
    end
    failed 'when the role is a ta' do
      let(:role) { create(:ta) }
      succeed 'that can manage annotations' do
        let(:role) { create(:ta, manage_assessments: true) }
      end
    end
    failed 'when the role is a student' do
      let(:role) { create(:student) }
    end
  end
  describe_rule :read? do
    succeed 'when the role is an admin' do
      let(:role) { build(:admin) }
    end
    succeed 'when the role is a ta' do
      let(:role) { build(:ta) }
    end
    failed 'when the role is a student' do
      let(:role) { build(:student) }
    end
  end
end
