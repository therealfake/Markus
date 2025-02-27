shared_examples 'a controller supporting upload' do |formats: [:yml, :csv], background: false, route_name: :upload|
  before :each do
    @initial_count = model_count
  end
  let(:instructor) { create :instructor }

  it 'does not accept request without an uploaded file' do
    post_as instructor, route_name, params: params

    expect(flash[:error]).not_to be_empty
    expect(model_count).to eq @initial_count
  end

  it 'does not accept an xls file' do
    post_as instructor, route_name, params: {
      **params,
      upload_file: fixture_file_upload('wrong_csv_format.xls')
    }
    expect(flash[:error]).to_not be_empty
    expect(model_count).to eq @initial_count
  end

  formats.each do |format|
    context "in #{format}" do
      it 'does not accept an empty file' do
        post_as instructor, route_name, params: {
          **params,
          upload_file: fixture_file_upload("upload_shared_files/empty.#{format}")
        }

        expect(flash[:error]).not_to be_empty
        expect(model_count).to eq @initial_count
      end

      unless background
        # This is not checked right away if the file content is sent to a background job for later processing
        it "does not accept an invalid file even with a .#{format} extension" do
          post_as instructor, route_name, params: {
            **params,
            upload_file: fixture_file_upload("upload_shared_files/bad_#{format}.#{format}")
          }

          expect(flash[:error]).to_not be_empty
          expect(model_count).to eq @initial_count
        end
      end
    end
  end

  private

  def model_count
    if params[:model]
      params[:model].count
    else
      controller.controller_name.classify.constantize.count
    end
  end
end
