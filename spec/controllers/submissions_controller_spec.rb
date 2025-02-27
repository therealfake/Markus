describe SubmissionsController do
  # TODO: add 'role is from a different course' shared tests to each route test below
  let(:course) { Course.first || create(:course) }
  shared_examples 'An authorized instructor and grader accessing #set_result_marking_state' do
    context '#set_result_marking_state' do
      let(:marking_state) { Result::MARKING_STATES[:complete] }
      let(:released_to_students) { false }
      let(:new_marking_state) { Result::MARKING_STATES[:incomplete] }
      before :each do
        @current_result = grouping.current_result
        @current_result.update!(marking_state: marking_state, released_to_students: released_to_students)
        post_as role, :set_result_marking_state, params: { course_id: course.id,
                                                           assignment_id: @assignment.id,
                                                           groupings: [grouping.id],
                                                           marking_state: new_marking_state }
        @current_result.reload
      end
      context 'when the marking state is complete' do
        let(:new_marking_state) { Result::MARKING_STATES[:incomplete] }
        it 'should be able to bulk set the marking state to incomplete' do
          expect(@current_result.marking_state).to eq new_marking_state
        end

        it 'should be successful' do
          expect(response).to have_http_status(:success)
        end

        context 'when the result is released' do
          let(:released_to_students) { true }
          it 'should not be able to bulk set the marking state to complete' do
            expect(@current_result.marking_state).not_to eq new_marking_state
          end

          it 'should still respond as a success' do
            expect(response).to have_http_status(:success)
          end

          it 'should flash an error messages' do
            expect(flash[:error].size).to be 1
          end
        end
      end

      context 'when the marking state is incomplete' do
        let(:marking_state) { Result::MARKING_STATES[:incomplete] }
        let(:new_marking_state) { Result::MARKING_STATES[:complete] }
        it 'should be able to bulk set the marking state to complete' do
          expect(@current_result.marking_state).to eq new_marking_state
        end

        it 'should be successful' do
          expect(response).to have_http_status(:success)
        end
      end
    end
  end

  describe 'A student working alone' do
    before(:each) do
      @group = create(:group)
      @assignment = create(:assignment, course: @group.course)
      @grouping = create(:grouping,
                         group: @group,
                         assignment: @assignment)
      @membership = create(:student_membership,
                           membership_status: 'inviter',
                           grouping: @grouping)
      @student = @membership.role
      request.env['HTTP_REFERER'] = 'back'
    end

    it 'should be rejected if it is a scanned assignment' do
      assignment = create(:assignment_for_scanned_exam)
      create(:grouping_with_inviter, inviter: @student, assignment: assignment)
      get_as @student, :file_manager, params: { course_id: course.id, assignment_id: assignment.id }
      expect(response).to have_http_status 403
    end

    it 'should be rejected if it is a timed assignment and the student has not yet started' do
      assignment = create(:timed_assignment)
      create(:grouping_with_inviter, inviter: @student, assignment: assignment)
      get_as @student, :file_manager, params: { course_id: course.id, assignment_id: assignment.id }
      expect(response).to have_http_status 403
    end

    it 'should not be rejected if it is a timed assignment and the student has started' do
      assignment = create(:timed_assignment)
      create(:grouping_with_inviter, inviter: @student, assignment: assignment, start_time: 10.minutes.ago)
      get_as @student, :file_manager, params: { course_id: course.id, assignment_id: assignment.id }
      expect(response).to have_http_status 200
    end

    it 'should be able to add and access files' do
      file1 = fixture_file_upload('Shapes.java', 'text/java')
      file2 = fixture_file_upload('TestShapes.java', 'text/java')

      expect(@student.has_accepted_grouping_for?(@assignment.id)).to be_truthy
      post_as @student, :update_files,
              params: { course_id: course.id, assignment_id: @assignment.id, new_files: [file1, file2] }

      expect(response).to have_http_status :ok

      # update_files action assert assign to various instance variables.
      # These are crucial for the file_manager view to work properly.
      expect(assigns(:assignment)).to_not be_nil
      expect(assigns(:grouping)).to_not be_nil
      expect(assigns(:path)).to_not be_nil
      expect(assigns(:revision)).to_not be_nil
      expect(assigns(:files)).to_not be_nil
      expect(assigns(:missing_assignment_files)).to_not be_nil

      # Check to see if the file was added
      @grouping.group.access_repo do |repo|
        revision = repo.get_latest_revision
        files = revision.files_at_path(@assignment.repository_folder)
        expect(files['Shapes.java']).to_not be_nil
        expect(files['TestShapes.java']).to_not be_nil
      end
    end

    context 'submitting a url' do
      describe 'should add url files' do
        before :each do
          @assignment.update!(url_submit: true)
        end
        it 'returns ok response' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_url: 'https://www.youtube.com/watch?v=dtGs7Fy8ISo', url_text: 'youtube' }
          expect(response).to have_http_status :ok
        end

        it 'added a new file' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_url: 'https://www.youtube.com/watch?v=dtGs7Fy8ISo', url_text: 'youtube' }
          @grouping.group.access_repo do |repo|
            revision = repo.get_latest_revision
            files = revision.files_at_path(@assignment.repository_folder)
            expect(files['youtube.markusurl']).to_not be_nil
          end
        end

        it 'with the correct content' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_url: 'https://www.youtube.com/watch?v=dtGs7Fy8ISo', url_text: 'youtube' }
          @grouping.group.access_repo do |repo|
            revision = repo.get_latest_revision
            files = revision.files_at_path(@assignment.repository_folder)
            file_content = repo.download_as_string(files['youtube.markusurl'])
            expect(file_content).to eq('https://www.youtube.com/watch?v=dtGs7Fy8ISo')
          end
        end
      end

      describe 'should reject url with no name' do
        before :each do
          @assignment.update!(url_submit: true)
        end
        it 'returns a bad request' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_url: 'https://www.youtube.com/watch?v=dtGs7Fy8ISo' }
          expect(response).to have_http_status :bad_request
        end

        it 'does not add a new file' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_url: 'https://www.youtube.com/watch?v=dtGs7Fy8ISo' }
          @grouping.group.access_repo do |repo|
            revision = repo.get_latest_revision
            files = revision.files_at_path(@assignment.repository_folder)
            expect(files['youtube.markusurl']).to be_nil
          end
        end
      end

      describe 'should reject invalid url' do
        before :each do
          @assignment.update!(url_submit: true)
        end
        it 'returns a bad request' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_url: 'Not a url', url_text: 'youtube' }
          expect(response).to have_http_status :bad_request
        end

        it 'does not add a new file' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_url: 'Not a url', url_text: 'youtube' }
          @grouping.group.access_repo do |repo|
            revision = repo.get_latest_revision
            files = revision.files_at_path(@assignment.repository_folder)
            expect(files['youtube.markusurl']).to be_nil
          end
        end
      end

      describe 'should reject url when option is disabled' do
        it 'returns a bad request' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_url: 'https://www.youtube.com/watch?v=dtGs7Fy8ISo', url_text: 'youtube' }
          expect(response).to have_http_status :bad_request
        end

        it 'does not add a new file' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_url: 'https://www.youtube.com/watch?v=dtGs7Fy8ISo', url_text: 'youtube' }
          @grouping.group.access_repo do |repo|
            revision = repo.get_latest_revision
            files = revision.files_at_path(@assignment.repository_folder)
            expect(files['youtube.markusurl']).to be_nil
          end
        end
      end
    end

    context 'when the grouping is invalid' do
      it 'should not be able to add files' do
        @assignment.update!(group_min: 2, group_max: 3)
        file1 = fixture_file_upload('Shapes.java', 'text/java')
        file2 = fixture_file_upload('TestShapes.java', 'text/java')

        expect(@student.has_accepted_grouping_for?(@assignment.id)).to be_truthy
        post_as @student, :update_files,
                params: { course_id: course.id, assignment_id: @assignment.id, new_files: [file1, file2] }

        expect(response).to have_http_status :bad_request

        # Check that the files were not added
        @grouping.group.access_repo do |repo|
          revision = repo.get_latest_revision
          files = revision.files_at_path(@assignment.repository_folder)
          expect(files['Shapes.java']).to be_nil
          expect(files['TestShapes.java']).to be_nil
        end
      end
    end

    context 'when only required files can be submitted' do
      before :each do
        @assignment.update(
          only_required_files: true,
          assignment_files_attributes: [{ filename: 'Shapes.java' }]
        )
      end

      it 'should be able to add and access files when uploading only required files' do
        file1 = fixture_file_upload('Shapes.java', 'text/java')

        post_as @student, :update_files,
                params: { course_id: course.id, assignment_id: @assignment.id, new_files: [file1] }

        expect(response).to have_http_status :ok

        # Check to see if the file was added
        @grouping.group.access_repo do |repo|
          revision = repo.get_latest_revision
          files = revision.files_at_path(@assignment.repository_folder)
          expect(files['Shapes.java']).to_not be_nil
        end
      end

      it 'should not be able to add and access files when uploading at least one non-required file' do
        file1 = fixture_file_upload('Shapes.java', 'text/java')
        file2 = fixture_file_upload('TestShapes.java', 'text/java')

        post_as @student, :update_files,
                params: { course_id: course.id, assignment_id: @assignment.id, new_files: [file1, file2] }

        expect(response).to have_http_status :unprocessable_entity

        # Check to see if the file was added
        @grouping.group.access_repo do |repo|
          revision = repo.get_latest_revision
          files = revision.files_at_path(@assignment.repository_folder)
          expect(files['Shapes.java']).to be_nil
          expect(files['TestShapes.java']).to be_nil
        end
      end

      context 'when creating a folder with required files' do
        let(:tree) do
          @grouping.group.access_repo do |repo|
            repo.get_latest_revision.tree_at_path(@assignment.repository_folder)
          end
        end
        before :each do
          @assignment.update!(
            only_required_files: true,
            assignment_files_attributes: [{ filename: 'test_zip/zip_subdir/TestShapes.java' }]
          )
        end
        it 'uploads a directory and returns a success' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_folders: ['test_zip'] }
          expect(response).to have_http_status :ok
        end
        it 'commits a single directory' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_folders: ['test_zip'] }
          expect(tree['test_zip']).not_to be_nil
        end
        it 'uploads a subdirectory' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_folders: ['test_zip'] }
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_folders: ['test_zip/zip_subdir'] }
          expect(response).to have_http_status :ok
        end
        it 'commits a subdirectory' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_folders: ['test_zip'] }
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_folders: ['test_zip/zip_subdir'] }
          expect(tree['test_zip/zip_subdir']).not_to be_nil
        end
        context 'when testing with a git repo', :keep_memory_repos do
          before(:each) { allow(Settings.repository).to receive(:type).and_return('git') }
          after(:each) { FileUtils.rm_r(Dir.glob(File.join(Settings.repository.storage, '*'))) }
          it 'displays a failure message when attempting to create a subdirectory with no parent' do
            post_as @student, :update_files,
                    params: { course_id: course.id, assignment_id: @assignment.id,
                              new_folders: ['test_zip/zip_subdir'] }

            expect(flash[:error]).to_not be_empty
          end
        end
        it 'does not upload a non required directory and returns a failure' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_folders: ['bad_folder'] }
          expect(response).to have_http_status :unprocessable_entity
        end
        it 'does not commit the non required directory' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_folders: ['bad_folder'] }
          expect(tree['bad_folder']).to be_nil
        end
        it 'does not upload a non required subdirectory' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_folders: ['bad_folder/bad_subdirectory'] }
          expect(response).to have_http_status :unprocessable_entity
        end
        it 'does not commit a non required subdirectory' do
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_folders: ['bad_folder/bad_subdirectory'] }
          expect(tree['bad_folder/bad_subdirectory']).to be_nil
        end
      end

      context 'when folders are required and uploading a zip file' do
        let(:unzip) { 'true' }
        before :each do
          @assignment.update!(
            only_required_files: true,
            assignment_files_attributes: [{ filename: 'test_zip/zip_subdir/TestShapes.java' },
                                          { filename: 'test_zip/Shapes.java' }]
          )
        end

        it 'should be able to create required folders' do
          zip_file = fixture_file_upload('test_zip.zip', 'application/zip')
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_files: [zip_file], unzip: unzip }

          expect(response).to have_http_status :ok
        end
        it 'uploads the outer directory' do
          zip_file = fixture_file_upload('test_zip.zip', 'application/zip')
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_files: [zip_file], unzip: unzip }
          tree = @grouping.group.access_repo do |repo|
            repo.get_latest_revision.tree_at_path(@assignment.repository_folder)
          end
          expect(tree['test_zip']).not_to be_nil
        end
        it 'uploads the inner directory' do
          zip_file = fixture_file_upload('test_zip.zip', 'application/zip')
          post_as @student, :update_files,
                  params: { course_id: course.id, assignment_id: @assignment.id,
                            new_files: [zip_file], unzip: unzip }
          tree = @grouping.group.access_repo do |repo|
            repo.get_latest_revision.tree_at_path(@assignment.repository_folder)
          end
          expect(tree['test_zip/zip_subdir']).not_to be_nil
        end
      end
    end

    context 'uploading a zip file' do
      let(:unzip) { 'true' }
      let(:tree) do
        zip_file = fixture_file_upload('test_zip.zip', 'application/zip')
        post_as @student, :update_files,
                params: { course_id: course.id, assignment_id: @assignment.id, new_files: [zip_file], unzip: unzip }
        @grouping.group.access_repo do |repo|
          repo.get_latest_revision.tree_at_path(@assignment.repository_folder)
        end
      end
      context 'when unzip if false' do
        let(:unzip) { 'false' }
        it 'should just upload the zip file as is' do
          expect(tree['test_zip.zip']).not_to be_nil
        end
        it 'should not upload any other files' do
          expect(tree.length).to eq 1
        end
      end
      it 'should not upload the zip file' do
        expect(tree['test_zip.zip']).to be_nil
      end
      it 'should upload the outer dir' do
        expect(tree['test_zip']).not_to be_nil
      end
      it 'should upload the inner dir' do
        expect(tree['test_zip/zip_subdir']).not_to be_nil
      end
      it 'should upload a file in the outer dir' do
        expect(tree['test_zip/Shapes.java']).not_to be_nil
      end
      it 'should upload a file in the inner dir' do
        expect(tree['test_zip/zip_subdir/TestShapes.java']).not_to be_nil
      end
    end

    it 'should be able to populate the file manager' do
      get_as @student, :populate_file_manager,
             params: { course_id: course.id, assignment_id: @assignment.id }, format: 'json'
      is_expected.to respond_with(:success)
    end

    it 'should be able to access file manager page' do
      get_as @student, :file_manager,
             params: { course_id: course.id, assignment_id: @assignment.id }
      is_expected.to respond_with(:success)
      # file_manager action assert assign to various instance variables.
      # These are crucial for the file_manager view to work properly.
      expect(assigns(:assignment)).to_not be_nil
      expect(assigns(:grouping)).to_not be_nil
      expect(assigns(:path)).to_not be_nil
      expect(assigns(:revision)).to_not be_nil
      expect(assigns(:files)).to_not be_nil
      expect(assigns(:missing_assignment_files)).to_not be_nil
    end

    it 'should render with the assignment content layout' do
      get_as @student, :file_manager,
             params: { course_id: course.id, assignment_id: @assignment.id }
      expect(response).to render_template('layouts/assignment_content')
    end

    # TODO: figure out how to test this test into the one above
    # TODO Figure out how to remove fixture_file_upload
    it 'should be able to replace files' do
      expect(@student.has_accepted_grouping_for?(@assignment.id)).to be_truthy

      @grouping.group.access_repo do |repo|
        txn = repo.get_transaction('markus')
        # overwrite and commit both files
        txn.add(File.join(@assignment.repository_folder, 'Shapes.java'),
                'Content of Shapes.java')
        txn.add(File.join(@assignment.repository_folder, 'TestShapes.java'),
                'Content of TestShapes.java')
        repo.commit(txn)

        # revision 2
        revision = repo.get_latest_revision
        old_files = revision.files_at_path(@assignment.repository_folder)
        old_file1 = old_files['Shapes.java']
        old_file2 = old_files['TestShapes.java']

        @file1 = fixture_file_upload('Shapes.java', 'text/java')
        @file2 = fixture_file_upload('TestShapes.java', 'text/java')

        post_as @student,
                :update_files,
                params: { course_id: course.id, assignment_id: @assignment.id, new_files: [@file1, @file2],
                          file_revisions: { 'Shapes.java' => old_file1.from_revision,
                                            'TestShapes.java' => old_file2.from_revision } }
      end
      expect(response).to have_http_status :ok

      expect(assigns(:assignment)).to_not be_nil
      expect(assigns(:grouping)).to_not be_nil
      expect(assigns(:path)).to_not be_nil
      expect(assigns(:revision)).to_not be_nil
      expect(assigns(:files)).to_not be_nil
      expect(assigns(:missing_assignment_files)).to_not be_nil

      @grouping.group.access_repo do |repo|
        revision = repo.get_latest_revision
        files = revision.files_at_path(@assignment.repository_folder)
        expect(files['Shapes.java']).to_not be_nil
        expect(files['TestShapes.java']).to_not be_nil

        # Test to make sure that the contents were successfully updated
        @file1.rewind
        @file2.rewind
        file_1_new_contents = repo.download_as_string(files['Shapes.java'])
        file_2_new_contents = repo.download_as_string(files['TestShapes.java'])

        expect(@file1.read).to eq(file_1_new_contents)
        expect(@file2.read).to eq(file_2_new_contents)
      end
    end

    it 'should be able to delete files' do
      expect(@student.has_accepted_grouping_for?(@assignment.id)).to be_truthy

      @grouping.group.access_repo do |repo|
        txn = repo.get_transaction('markus')
        txn.add(File.join(@assignment.repository_folder, 'Shapes.java'),
                'Content of Shapes.java')
        txn.add(File.join(@assignment.repository_folder, 'TestShapes.java'),
                'Content of TestShapes.java')
        repo.commit(txn)
        revision = repo.get_latest_revision
        old_files = revision.files_at_path(@assignment.repository_folder)
        old_file1 = old_files['Shapes.java']
        old_file2 = old_files['TestShapes.java']

        post_as @student,
                :update_files,
                params: { course_id: course.id, assignment_id: @assignment.id, delete_files: ['Shapes.java'],
                          file_revisions: { 'Shapes.java' => old_file1.from_revision,
                                            'TestShapes.java' => old_file2.from_revision } }
      end

      expect(response).to have_http_status :ok

      expect(assigns(:assignment)).to_not be_nil
      expect(assigns(:grouping)).to_not be_nil
      expect(assigns(:path)).to_not be_nil
      expect(assigns(:revision)).to_not be_nil
      expect(assigns(:files)).to_not be_nil
      expect(assigns(:missing_assignment_files)).to_not be_nil

      @grouping.group.access_repo do |repo|
        revision = repo.get_latest_revision
        files = revision.files_at_path(@assignment.repository_folder)
        expect(files['Shapes.java']).to be_nil
        expect(files['TestShapes.java']).to_not be_nil
      end
    end

    # Repository Browser Tests
    # TODO:  TEST REPO BROWSER HERE
    it 'should not be able to use the repository browser' do
      get_as @student, :repo_browser,
             params: { course_id: course.id, assignment_id: @assignment.id, grouping_id: Grouping.last.id }
      is_expected.to respond_with(:forbidden)
    end

    # Stopping a curious student
    it 'should not be able download svn checkout commands' do
      get_as @student, :download_repo_checkout_commands, params: { course_id: course.id, assignment_id: @assignment.id }

      is_expected.to respond_with(:forbidden)
    end

    it 'should not be able to download the svn repository list' do
      get_as @student, :download_repo_list, params: { course_id: course.id, assignment_id: @assignment.id }

      is_expected.to respond_with(:forbidden)
    end
  end

  describe 'A grader' do
    let(:grader) { create(:ta) }
    let(:grader_permission) { grader.grader_permission }
    before(:each) do
      @group = create(:group)
      @assignment = create(:assignment, course: @group.course)
      @grouping = create(:grouping,
                         group: @group,
                         assignment: @assignment)
      @membership = create(:student_membership,
                           membership_status: 'inviter',
                           grouping: @grouping)
      @student = @membership.role

      @grouping1 = create(:grouping,
                          assignment: @assignment)
      @grouping1.group.access_repo do |repo|
        txn = repo.get_transaction('test')
        path = File.join(@assignment.repository_folder, 'file1_name')
        txn.add(path, 'file1 content', '')
        repo.commit(txn)

        # Generate submission
        submission = Submission.generate_new_submission(Grouping.last,
                                                        repo.get_latest_revision)
        result = submission.get_latest_result
        result.marking_state = Result::MARKING_STATES[:complete]
        result.save
        submission.save
      end
    end
    context '#set_resulting_marking_state' do
      let(:role) { create(:ta) }
      let(:grouping) { @grouping1 }
      include_examples 'An authorized instructor and grader accessing #set_result_marking_state'
    end
    it 'should be able to access the repository browser.' do
      revision_identifier = Grouping.last.group.access_repo { |repo| repo.get_latest_revision.revision_identifier }
      get_as grader,
             :repo_browser,
             params: { course_id: course.id, assignment_id: @assignment.id, grouping_id: Grouping.last.id,
                       revision_identifier: revision_identifier,
                       path: '/' }
      is_expected.to respond_with(:success)
    end

    it 'should render with the assignment_content layout' do
      revision_identifier = Grouping.last.group.access_repo { |repo| repo.get_latest_revision.revision_identifier }
      get_as grader,
             :repo_browser,
             params: { course_id: course.id, assignment_id: @assignment.id, grouping_id: Grouping.last.id,
                       revision_identifier: revision_identifier,
                       path: '/' }
      expect(response).to render_template('layouts/assignment_content')
    end

    it 'should be able to download the svn checkout commands' do
      get_as grader, :download_repo_checkout_commands, params: { course_id: course.id, assignment_id: @assignment.id }
      is_expected.to respond_with(:forbidden)
    end

    it 'should be able to download the svn repository list' do
      get_as grader, :download_repo_list, params: { course_id: course.id, assignment_id: @assignment.id }
      is_expected.to respond_with(:forbidden)
    end

    let(:revision_identifier) do
      @grouping.group.access_repo { |repo| repo.get_latest_revision.revision_identifier }
    end

    describe 'When grader is allowed to collect and update submissions' do
      before do
        grader_permission.manage_submissions = true
        grader_permission.save
      end
      context '#collect_submissions' do
        before do
          post_as grader, :collect_submissions,
                  params: { course_id: course.id, assignment_id: @assignment.id, groupings: [@grouping.id] }
        end
        it('should respond with 200') { expect(response.status).to eq 200 }
      end
      context '#manually_collect_and_begin_grading' do
        before do
          post_as grader, :manually_collect_and_begin_grading,
                  params: { course_id: course.id, assignment_id: @assignment.id, grouping_id: @grouping.id,
                            current_revision_identifier: revision_identifier }
        end
        it('should respond with 302') { expect(response.status).to eq 302 }
      end
      context '#update submissions' do
        it 'should respond with 302' do
          post_as grader,
                  :update_submissions,
                  params: { course_id: course.id,
                            assignment_id: @assignment.id,
                            groupings: [@grouping1.id],
                            release_results: 'true' }
          is_expected.to respond_with(:success)
        end
      end
    end

    describe 'When grader is not allowed to collect and update submissions' do
      before do
        grader_permission.manage_submissions = false
        grader_permission.save
      end
      context '#collect_submissions' do
        before do
          post_as grader, :collect_submissions,
                  params: { course_id: course.id, assignment_id: @assignment.id, groupings: [@grouping.id] }
        end
        it('should respond with 403') { expect(response.status).to eq 403 }
      end
      context '#manually_collect_and_begin_grading' do
        before do
          post_as grader, :manually_collect_and_begin_grading,
                  params: { course_id: course.id, assignment_id: @assignment.id, grouping_id: @grouping.id,
                            current_revision_identifier: revision_identifier }
        end
        it('should respond with 403') { expect(response.status).to eq 403 }
      end
      context '#update submissions' do
        it 'should respond with 403' do
          post_as grader,
                  :update_submissions,
                  params: { course_id: course.id,
                            assignment_id: @assignment.id,
                            groupings: ([] << @assignment.groupings).flatten,
                            release_results: 'true' }
          expect(response.status).to eq 403
        end
      end
    end
  end

  describe 'An administrator' do
    before(:each) do
      @group = create(:group)
      @assignment = create(:assignment, course: @group.course)
      @grouping = create(:grouping,
                         group: @group,
                         assignment: @assignment)
      @membership = create(:student_membership,
                           membership_status: 'inviter',
                           grouping: @grouping)
      @student = @membership.role
      @instructor = create(:instructor)
      @csv_options = {
        type: 'text/csv',
        disposition: 'attachment',
        filename: "#{@assignment.short_identifier}_simple_report.csv"
      }
    end

    it 'should be able to access the repository browser' do
      get_as @instructor, :repo_browser,
             params: { course_id: course.id, assignment_id: @assignment.id, grouping_id: Grouping.last.id, path: '/' }
      is_expected.to respond_with(:success)
    end

    it 'should render with the assignment_content layout' do
      get_as @instructor, :repo_browser,
             params: { course_id: course.id, assignment_id: @assignment.id, grouping_id: Grouping.last.id, path: '/' }
      expect(response).to render_template(layout: 'layouts/assignment_content')
    end

    it 'should be able to download the svn checkout commands' do
      get_as @instructor, :download_repo_checkout_commands,
             params: { course_id: course.id, assignment_id: @assignment.id }
      is_expected.to respond_with(:success)
    end

    it 'should be able to download the svn repository list' do
      get_as @instructor, :download_repo_list, params: { course_id: course.id, assignment_id: @assignment.id }
      is_expected.to respond_with(:success)
    end

    describe 'attempting to collect submissions' do
      before(:each) do
        @grouping.group.access_repo do |repo|
          txn = repo.get_transaction('test')
          path = File.join(@assignment.repository_folder, 'file1_name')
          txn.add(path, 'file1 content', '')
          repo.commit(txn)

          # Generate submission
          submission =
            Submission.generate_new_submission(@grouping,
                                               repo.get_latest_revision)
          result = submission.get_latest_result
          result.marking_state = Result::MARKING_STATES[:complete]
          result.save
          submission.save
        end
        @grouping.update! is_collected: true
      end

      around { |example| perform_enqueued_jobs(&example) }

      context '#set_resulting_marking_state' do
        let(:role) { create(:ta) }
        let(:grouping) { @grouping }
        include_examples 'An authorized instructor and grader accessing #set_result_marking_state'
      end

      context 'where a grouping does not have a previously collected submission' do
        let(:uncollected_grouping) { create(:grouping, assignment: @assignment) }
        before(:each) do
          uncollected_grouping.group.access_repo do |repo|
            txn = repo.get_transaction('test')
            path = File.join(@assignment.repository_folder, 'file1_name')
            txn.add(path, 'file1 content', '')
            repo.commit(txn)
          end
        end

        it 'should collect all groupings when override is true' do
          @assignment.update!(due_date: 1.week.ago)
          allow(SubmissionsJob).to receive(:perform_later) { Struct.new(:job_id).new('1') }
          expect(SubmissionsJob).to receive(:perform_later).with(
            array_including(@grouping, uncollected_grouping),
            collection_dates: hash_including
          )
          post_as @instructor, :collect_submissions, params: { course_id: course.id,
                                                               assignment_id: @assignment.id,
                                                               groupings: [@grouping.id, uncollected_grouping.id],
                                                               override: true }
        end

        it 'should collect the uncollected grouping only when override is false' do
          @assignment.update!(due_date: 1.week.ago)
          allow(SubmissionsJob).to receive(:perform_later) { Struct.new(:job_id).new('1') }
          expect(SubmissionsJob).to receive(:perform_later).with(
            [uncollected_grouping],
            collection_dates: hash_including
          )
          post_as @instructor, :collect_submissions, params: { course_id: course.id,
                                                               assignment_id: @assignment.id,
                                                               groupings: [@grouping.id, uncollected_grouping.id],
                                                               override: false }
        end
      end

      context 'when updating students on submission results' do
        it 'should be able to release submissions' do
          allow(Assignment).to receive(:find) { @assignment }
          post_as @instructor,
                  :update_submissions,
                  params: { course_id: course.id,
                            assignment_id: @assignment.id,
                            groupings: ([] << @assignment.groupings).flatten,
                            release_results: 'true' }
          is_expected.to respond_with(:success)
        end
        context 'with one grouping selected' do
          it 'sends an email to the student if only one student exists in the grouping' do
            expect do
              post_as @instructor,
                      :update_submissions,
                      params: { course_id: course.id,
                                assignment_id: @assignment.id,
                                groupings: ([] << @assignment.groupings).flatten,
                                release_results: 'true' }
            end.to change { ActionMailer::Base.deliveries.count }.by(1)
          end
          it 'sends an email to every student in a grouping if it has multiple students' do
            create(:student_membership, membership_status: 'inviter', grouping: @grouping)
            expect do
              post_as @instructor,
                      :update_submissions,
                      params: { course_id: course.id,
                                assignment_id: @assignment.id,
                                groupings: ([] << @assignment.groupings).flatten,
                                release_results: 'true' }
            end.to change { ActionMailer::Base.deliveries.count }.by(2)
          end
          it 'does not send an email to some students in a grouping if some have emails disabled' do
            another_membership = create(:student_membership, membership_status: 'inviter', grouping: @grouping)
            another_membership.role.update!(receives_results_emails: false)
            expect do
              post_as @instructor,
                      :update_submissions,
                      params: { course_id: course.id,
                                assignment_id: @assignment.id,
                                groupings: ([] << @assignment.groupings).flatten,
                                release_results: 'true' }
            end.to change { ActionMailer::Base.deliveries.count }.by(1)
          end
        end
        context 'with several groupings selected' do
          it 'sends emails to students in every grouping selected if more than one grouping is selected' do
            other_grouping = create(:grouping, assignment: @assignment)
            create(:student_membership, membership_status: 'inviter', grouping: other_grouping)
            other_grouping.group.access_repo do |repo|
              txn = repo.get_transaction('test')
              path = File.join(@assignment.repository_folder, 'file1_name')
              txn.add(path, 'file1 content', '')
              repo.commit(txn)
              # Generate submission
              submission = Submission.generate_new_submission(other_grouping, repo.get_latest_revision)
              result = submission.get_latest_result
              result.marking_state = Result::MARKING_STATES[:complete]
              result.save
              submission.save
            end
            other_grouping.update! is_collected: true
            expect do
              post_as @instructor,
                      :update_submissions,
                      params: { course_id: course.id,
                                assignment_id: @assignment.id,
                                groupings: ([] << @assignment.groupings).flatten,
                                release_results: 'true' }
            end.to change { ActionMailer::Base.deliveries.count }.by(2)
          end
          it 'does not email some students in some groupings if those students have them disabled' do
            other_grouping = create(:grouping, assignment: @assignment)
            other_membership = create(:student_membership, membership_status: 'inviter', grouping: other_grouping)
            other_membership.role.update!(receives_results_emails: false)
            other_grouping.group.access_repo do |repo|
              txn = repo.get_transaction('test')
              path = File.join(@assignment.repository_folder, 'file1_name')
              txn.add(path, 'file1 content', '')
              repo.commit(txn)
              # Generate submission
              submission = Submission.generate_new_submission(other_grouping, repo.get_latest_revision)
              result = submission.get_latest_result
              result.marking_state = Result::MARKING_STATES[:complete]
              result.save
              submission.save
            end
            other_grouping.update! is_collected: true
            expect do
              post_as @instructor,
                      :update_submissions,
                      params: { course_id: course.id,
                                assignment_id: @assignment.id,
                                groupings: ([] << @assignment.groupings).flatten,
                                release_results: 'true' }
            end.to change { ActionMailer::Base.deliveries.count }.by(1)
          end
        end
      end

      context 'of selected groupings' do
        it 'should get an error if no groupings are selected' do
          post_as @instructor, :collect_submissions,
                  params: { course_id: course.id, assignment_id: @assignment.id, groupings: [] }

          is_expected.to respond_with(:bad_request)
        end

        context 'with a section' do
          before(:each) do
            @section = create(:section, name: 's1')
            @assessment_section_properties = create(:assessment_section_properties, section: @section,
                                                                                    assessment: @assignment)
            @student.section = @section
            @student.save
          end

          it 'should get an error if it is before the section due date' do
            @assessment_section_properties.update!(due_date: 1.week.from_now)
            allow(Assignment).to receive_message_chain(
              :includes, :find
            ) { @assignment }
            expect_any_instance_of(SubmissionsController).to receive(:flash_now).with(:error, anything)
            expect(@assignment).to receive(:short_identifier) { 'a1' }
            allow(SubmissionsJob).to receive(:perform_later) { Struct.new(:job_id).new('1') }

            post_as @instructor,
                    :collect_submissions,
                    params: { course_id: course.id, assignment_id: @assignment.id,
                              override: true, groupings: ([] << @assignment.groupings).flatten }

            expect(response).to render_template(partial: 'shared/_poll_job')
          end

          it 'should succeed if it is after the section due date' do
            @assessment_section_properties.update!(due_date: 1.week.ago)
            allow(Assignment).to receive_message_chain(
              :includes, :find
            ) { @assignment }
            expect_any_instance_of(SubmissionsController).not_to receive(:flash_now).with(:error, anything)
            allow(SubmissionsJob).to receive(:perform_later) { Struct.new(:job_id).new('1') }

            post_as @instructor,
                    :collect_submissions,
                    params: { course_id: course.id, assignment_id: @assignment.id,
                              override: true, groupings: ([] << @assignment.groupings).flatten }

            expect(response).to render_template(partial: 'shared/_poll_job')
          end
        end

        context 'without a section' do
          before(:each) do
            @student.section = nil
            @student.save
          end

          it 'should get an error if it is before the global due date' do
            @assignment.update!(due_date: 1.week.from_now)
            allow(Assignment).to receive_message_chain(
              :includes, :find
            ) { @assignment }
            expect(@assignment).to receive(:short_identifier) { 'a1' }
            expect_any_instance_of(SubmissionsController).to receive(:flash_now).with(:error, anything)
            allow(SubmissionsJob).to receive(:perform_later) { Struct.new(:job_id).new('1') }

            post_as @instructor,
                    :collect_submissions,
                    params: { course_id: course.id, assignment_id: @assignment.id,
                              override: true, groupings: ([] << @assignment.groupings).flatten }

            expect(response).to render_template(partial: 'shared/_poll_job')
          end

          it 'should succeed if it is after the global due date' do
            @assignment.update!(due_date: 1.week.ago)
            allow(Assignment).to receive_message_chain(
              :includes, :find
            ) { @assignment }
            expect_any_instance_of(SubmissionsController).not_to receive(:flash_now).with(:error, anything)
            allow(SubmissionsJob).to receive(:perform_later) { Struct.new(:job_id).new('1') }

            post_as @instructor,
                    :collect_submissions,
                    params: { course_id: course.id, assignment_id: @assignment.id,
                              override: true, groupings: ([] << @assignment.groupings).flatten }

            expect(response).to render_template(partial: 'shared/_poll_job')
          end
        end
      end
    end

    it 'download all files uploaded in a Zip file' do
      @file1_name = 'TestFile.java'
      @file2_name = 'SecondFile.go'
      @file1_content = "Some contents for TestFile.java\n"
      @file2_content = "Some contents for SecondFile.go\n"

      @group.access_repo do |repo|
        txn = repo.get_transaction('test')
        path = File.join(@assignment.repository_folder, @file1_name)
        txn.add(path, @file1_content, '')
        path = File.join(@assignment.repository_folder, @file2_name)
        txn.add(path, @file2_content, '')
        repo.commit(txn)

        # Generate submission
        @submission = Submission.generate_new_submission(
          @grouping,
          repo.get_latest_revision
        )
      end
      get_as @instructor,
             :downloads,
             params: { course_id: course.id, assignment_id: @assignment.id, grouping_id: @grouping.id }

      expect('application/zip').to eq(response.header['Content-Type'])
      is_expected.to respond_with(:success)
      revision_identifier = @grouping.group.access_repo { |repo| repo.get_latest_revision.revision_identifier }
      zip_path = "tmp/#{@assignment.short_identifier}_" \
                 "#{@grouping.group.group_name}_#{revision_identifier}.zip"
      Zip::File.open(zip_path) do |zip_file|
        file1_path = File.join("#{@assignment.short_identifier}-" +
                                   @grouping.group.group_name.to_s,
                               @file1_name)
        file2_path = File.join("#{@assignment.short_identifier}-" +
                                   @grouping.group.group_name.to_s,
                               @file2_name)
        expect(zip_file.find_entry(file1_path)).to_not be_nil
        expect(zip_file.find_entry(file2_path)).to_not be_nil

        expect(zip_file.read(file1_path)).to eq(@file1_content)
        expect(zip_file.read(file2_path)).to eq(@file2_content)
      end
    end

    it 'not be able to download an empty revision' do
      @group.access_repo do |repo|
        txn = repo.get_transaction('test')
        repo.commit(txn)

        # Generate submission
        @submission = Submission.generate_new_submission(
          @grouping,
          repo.get_latest_revision
        )
      end

      request.env['HTTP_REFERER'] = 'back'
      get_as @instructor,
             :downloads,
             params: { course_id: course.id, assignment_id: @assignment.id, grouping_id: @grouping.id }

      is_expected.to respond_with(:redirect)
    end

    it 'not be able to download the revision 0' do
      @group.access_repo do |repo|
        txn = repo.get_transaction('test')
        path = File.join(@assignment.repository_folder, 'file1_name')
        txn.add(path, 'file1 content', '')
        repo.commit(txn)

        # Generate submission
        @submission = Submission.generate_new_submission(
          @grouping,
          repo.get_latest_revision
        )
      end
      request.env['HTTP_REFERER'] = 'back'
      get_as @instructor,
             :downloads,
             params: { course_id: course.id, assignment_id: @assignment.id, grouping_id: @grouping.id,
                       revision_identifier: 0 }

      is_expected.to respond_with(:redirect)
    end

    describe 'prepare and download a zip file' do
      let(:assignment) { create :assignment }
      let(:grouping_ids) do
        create_list(:grouping_with_inviter, 3, assignment: assignment).map.with_index do |grouping, i|
          submit_file(grouping.assignment, grouping, "file#{i}", "file#{i}'s content\n")
          grouping.id
        end
      end
      let(:unassigned_ta) { create :ta }
      let(:assigned_ta) do
        ta = create :ta
        grouping_ids # make sure groupings are created
        assignment.groupings.each do |grouping|
          create(:ta_membership, role: ta, grouping: grouping)
        end
        ta
      end

      describe '#zip_groupings_files' do
        it 'should be able to download all groups\' submissions' do
          expect(DownloadSubmissionsJob).to receive(:perform_later) do |grouping_ids, _zip_file, _assignment_id|
            expect(grouping_ids).to contain_exactly(*grouping_ids)
            DownloadSubmissionsJob.new
          end
          post_as @instructor, :zip_groupings_files,
                  params: { course_id: course.id, assignment_id: assignment.id, groupings: grouping_ids }
          is_expected.to respond_with(:success)
        end

        it 'should be able to download a subset of the submissions' do
          subset = grouping_ids[0...2]
          expect(DownloadSubmissionsJob).to receive(:perform_later) do |grouping_ids, _zip_file, _assignment_id|
            expect(grouping_ids).to contain_exactly(*subset)
            DownloadSubmissionsJob.new
          end
          post_as @instructor, :zip_groupings_files,
                  params: { course_id: course.id, assignment_id: assignment.id, groupings: subset }
          is_expected.to respond_with(:success)
        end

        it 'should - as Ta - be not able to download all groups\' submissions when unassigned' do
          expect(DownloadSubmissionsJob).to receive(:perform_later) do |grouping_ids, _zip_file, _assignment_id|
            expect(grouping_ids).to be_empty
            DownloadSubmissionsJob.new
          end
          post_as unassigned_ta, :zip_groupings_files,
                  params: { course_id: course.id, assignment_id: assignment.id, groupings: grouping_ids }
          is_expected.to respond_with(:success)
        end

        it 'should - as Ta - be able to download all groups\' submissions when assigned' do
          expect(DownloadSubmissionsJob).to receive(:perform_later) do |gids, _zip_file, _assignment_id|
            expect(gids).to contain_exactly(*grouping_ids)
            DownloadSubmissionsJob.new
          end
          post_as assigned_ta, :zip_groupings_files,
                  params: { course_id: course.id, assignment_id: assignment.id, groupings: grouping_ids }
          is_expected.to respond_with(:success)
        end

        it 'should create a zip file named after the current role and the assignment' do
          expect(DownloadSubmissionsJob).to receive(:perform_later) do |_grouping_ids, zip_file, _assignment_id|
            expect(zip_file).to include(assignment.short_identifier)
            expect(zip_file).to include(@instructor.user_name)
            DownloadSubmissionsJob.new
          end
          post_as @instructor, :zip_groupings_files,
                  params: { course_id: course.id, assignment_id: assignment.id, groupings: grouping_ids }
          is_expected.to respond_with(:success)
        end
      end

      describe '#download_zipped_file' do
        it 'should download a file name after the current role and the assignment' do
          expect(controller).to receive(:send_file) do |zip_file|
            expect(zip_file.to_s).to include(assignment.short_identifier)
            expect(zip_file.to_s).to include(@instructor.user_name)
          end
          post_as @instructor, :download_zipped_file, params: { course_id: course.id, assignment_id: assignment.id }
        end
      end
    end
  end

  describe 'An unauthenticated or unauthorized role' do
    let(:assignment) { create :assignment }
    it 'should not be able to download the svn checkout commands' do
      get :download_repo_checkout_commands, params: { course_id: course.id, assignment_id: assignment.id }
      is_expected.to respond_with(:redirect)
    end

    it 'should not be able to download the svn repository list' do
      get :download_repo_list, params: { course_id: course.id, assignment_id: assignment.id }
      is_expected.to respond_with(:redirect)
    end
  end

  describe '#download' do
    let(:assignment) { create(:assignment) }
    let(:instructor) { create(:instructor) }
    let(:grouping) { create(:grouping_with_inviter, assignment: assignment) }
    let(:file1) { fixture_file_upload('Shapes.java', 'text/java') }
    let(:file2) { fixture_file_upload('test_zip.zip', 'application/zip') }
    let(:file3) { fixture_file_upload('example.ipynb') }
    let(:file4) { fixture_file_upload('sample.markusurl') }
    let!(:submission) do
      submit_file(assignment, grouping, file1.original_filename, file1.read)
      submit_file(assignment, grouping, file2.original_filename, file2.read)
      submit_file(assignment, grouping, file3.original_filename, file3.read)
      submit_file(assignment, grouping, file4.original_filename, file4.read)
    end
    context 'When the file is in preview' do
      describe 'when the file is not a binary file' do
        it 'should display the file content' do
          get_as instructor, :download, params: { course_id: course.id,
                                                  assignment_id: assignment.id,
                                                  file_name: 'Shapes.java',
                                                  preview: true,
                                                  grouping_id: grouping.id }
          expect(response.body).to eq(File.read(file1))
        end
      end
      describe 'When the file is a jupyter notebook file' do
        subject do
          get_as instructor, :download, params: { course_id: course.id,
                                                  assignment_id: assignment.id,
                                                  file_name: 'example.ipynb',
                                                  preview: true,
                                                  grouping_id: grouping.id }
        end
        it 'should redirect to "notebook_content"' do
          expect(subject).to redirect_to(
            notebook_content_course_assignment_submissions_url(course_id: course.id,
                                                               assignment_id: assignment.id,
                                                               file_name: 'example.ipynb',
                                                               grouping_id: grouping.id)
          )
        end
      end
      describe 'When the file is an rmarkdown file' do
        subject do
          get_as instructor, :download, params: { course_id: course.id,
                                                  assignment_id: assignment.id,
                                                  file_name: 'example.Rmd',
                                                  preview: true,
                                                  grouping_id: grouping.id }
        end
        it 'should redirect to "notebook_content"' do
          expect(subject).to redirect_to(
            notebook_content_course_assignment_submissions_url(file_name: 'example.Rmd',
                                                               assignment_id: assignment.id,
                                                               grouping_id: grouping.id)
          )
        end
      end
      describe 'When the file is a binary file' do
        it 'should not display the contents of the compressed file' do
          get_as instructor, :download, params: { course_id: course.id,
                                                  assignment_id: assignment.id,
                                                  file_name: 'test_zip.zip',
                                                  preview: true,
                                                  grouping_id: grouping.id }
          expect(response.body).to eq(I18n.t('submissions.cannot_display'))
        end
      end
      describe 'When the file is a url file' do
        it 'should read the entire file' do
          assignment.update!(url_submit: true)
          get_as instructor, :download, params: { course_id: course.id,
                                                  assignment_id: assignment.id,
                                                  file_name: 'sample.markusurl',
                                                  preview: true,
                                                  grouping_id: grouping.id }
          expect(response.body).not_to eq(URI.extract(File.read(file4)).first)
        end
      end
    end
    context 'When the file is being downloaded' do
      describe 'when the file is not a binary file' do
        it 'should download the file' do
          get_as instructor, :download, params: { course_id: course.id,
                                                  assignment_id: assignment.id,
                                                  file_name: 'Shapes.java',
                                                  preview: false,
                                                  grouping_id: grouping.id }
          expect(response.body).to eq(File.read(file1))
        end
      end
      describe 'When the file is a jupyter notebook file' do
        it 'should download the file as is' do
          get_as instructor, :download, params: { course_id: course.id,
                                                  assignment_id: assignment.id,
                                                  file_name: 'example.ipynb',
                                                  preview: false,
                                                  grouping_id: grouping.id }
          expect(response.body).to eq(File.read(file3))
        end
      end
      describe 'When the file is a binary file' do
        it 'should download all the contents of the zip file' do
          get_as instructor, :download, params: { course_id: course.id,
                                                  assignment_id: assignment.id,
                                                  file_name: 'test_zip.zip',
                                                  preview: false,
                                                  grouping_id: grouping.id }
          grouping.group.access_repo do |repo|
            revision = repo.get_latest_revision
            file = revision.files_at_path(assignment.repository_folder)['test_zip.zip']
            content = repo.download_as_string(file)
            expect(response.body).to eq(content)
          end
        end
      end
      describe 'When the file is a url file' do
        it 'should download the file as is' do
          get_as instructor, :download, params: { course_id: course.id,
                                                  assignment_id: assignment.id,
                                                  file_name: 'sample.markusurl',
                                                  preview: false,
                                                  grouping_id: grouping.id }
          expect(response.body).to eq(File.read(file4))
        end
      end
    end
  end

  describe '#notebook_content' do
    let(:assignment) { create(:assignment) }
    let(:instructor) { create(:instructor) }
    let(:grouping) { create(:grouping_with_inviter, assignment: assignment) }
    let(:notebook_file) { fixture_file_upload(filename) }
    let(:submission) { submit_file(assignment, grouping, notebook_file.original_filename, notebook_file.read) }

    shared_examples 'notebook types' do
      shared_examples 'notebook content' do
        it 'is successful' do
          subject
          expect(response.status).to eq(200)
        end
        it 'renders the correct template' do
          expect(subject).to render_template('notebook')
        end
      end

      context 'a jupyter-notebook file' do
        let(:filename) { 'example.ipynb' }
        it_behaves_like 'notebook content'
      end
      context 'an rmarkdown file' do
        let(:filename) { 'example.Rmd' }
        it_behaves_like 'notebook content'
      end
    end

    context 'called with a collected submission' do
      let(:submission_file) { create :submission_file, submission: submission, filename: filename }
      subject do
        get_as instructor, :notebook_content,
               params: { course_id: course.id, assignment_id: assignment.id, select_file_id: submission_file.id }
      end
      it_behaves_like 'notebook types'
    end
    context 'called with a revision identifier' do
      subject do
        get_as instructor, :notebook_content, params: { course_id: course.id,
                                                        assignment_id: assignment.id,
                                                        file_name: filename,
                                                        grouping_id: grouping.id,
                                                        revision_identifier: submission.revision_identifier }
      end
      it_behaves_like 'notebook types'
    end
  end

  describe '#get_file' do
    let(:assignment) { create(:assignment) }
    let(:instructor) { create(:instructor) }
    let(:grouping) { create(:grouping_with_inviter, assignment: assignment) }
    let(:file1) { fixture_file_upload('Shapes.java', 'text/java') }
    let(:file2) { fixture_file_upload('test_zip.zip', 'application/zip', true) }
    let(:file3) { fixture_file_upload('example.ipynb') }
    let(:file4) { fixture_file_upload('page_white_text.png') }
    let(:file5) { fixture_file_upload('scanned_exams/midterm1-v2-test.pdf') }
    let(:file6) { fixture_file_upload('example.Rmd') }
    let(:file7) { fixture_file_upload('sample.markusurl') }
    let!(:submission) do
      files.map do |file|
        submit_file(assignment, grouping, file.original_filename, file.read)
      end.last
    end
    describe 'when the file is not a binary file' do
      let(:files) { [file1] }
      it 'should download the file' do
        submission_file = submission.submission_files.find_by(filename: file1.original_filename)
        get_as instructor, :get_file, params: { course_id: course.id,
                                                id: submission.id,
                                                submission_file_id: submission_file.id }
        expect(JSON.parse(response.body)['content']).to eq(ActiveSupport::JSON.encode(File.read(file1)))
      end
    end
    describe 'When the file is a jupyter notebook file' do
      let(:files) { [file3] }
      it 'should return the file type' do
        submission_file = submission.submission_files.find_by(filename: file3.original_filename)
        get_as instructor, :get_file, params: { course_id: course.id,
                                                id: submission.id,
                                                submission_file_id: submission_file.id }
        expect(JSON.parse(response.body)['type']).to eq 'jupyter-notebook'
      end
    end
    describe 'When the file is an rmarkdown notebook file' do
      let(:files) { [file6] }
      it 'should return the file type' do
        submission_file = submission.submission_files.find_by(filename: file6.original_filename)
        get_as instructor, :get_file, params: { course_id: course.id,
                                                id: submission.id,
                                                submission_file_id: submission_file.id }
        expect(JSON.parse(response.body)['type']).to eq 'rmarkdown'
      end
    end
    describe 'When the file is a binary file' do
      let(:files) { [file2] }
      it 'should download a warning instead of the file content' do
        submission_file = submission.submission_files.find_by(filename: file2.original_filename)
        get_as instructor, :get_file, params: { course_id: course.id,
                                                id: submission.id,
                                                submission_file_id: submission_file.id }
        expected = ActiveSupport::JSON.encode(I18n.t('submissions.cannot_display'))
        expect(JSON.parse(response.body)['content']).to eq(expected)
      end
      describe 'when force_text is true' do
        it 'should download the file content' do
          submission_file = submission.submission_files.find_by(filename: file2.original_filename)
          get_as instructor, :get_file, params: { course_id: course.id,
                                                  id: submission.id,
                                                  force_text: true,
                                                  submission_file_id: submission_file.id }
          file2.seek(0)
          actual = JSON.parse(JSON.parse(response.body)['content'])
          expected = file2.read.encode('UTF-8', invalid: :replace, undef: :replace, replace: '�')
          expect(actual).to eq(expected)
        end
      end
    end
    describe 'When the file is a url file' do
      context 'with a valid url file format' do
        let(:files) { [file7] }
        before :each do
          assignment.update!(url_submit: true)
        end
        it 'should return the file type' do
          submission_file = submission.submission_files.find_by(filename: file7.original_filename)
          get_as instructor, :get_file, params: { course_id: course.id,
                                                  id: submission.id,
                                                  submission_file_id: submission_file.id,
                                                  format: :json }
          expect(response.parsed_body['type']).to eq 'markusurl'
        end
      end
      context 'with urls disabled' do
        let(:files) { [file7] }
        it 'should return an unknown type' do
          submission_file = submission.submission_files.find_by(filename: file7.original_filename)
          get_as instructor, :get_file, params: { course_id: course.id,
                                                  id: submission.id,
                                                  submission_file_id: submission_file.id,
                                                  format: :json }
          expect(response.parsed_body['type']).to eq 'unknown'
        end
      end
    end
    describe 'when the file is an image' do
      let(:files) { [file4] }
      it 'should return the file type' do
        submission_file = submission.submission_files.find_by(filename: file4.original_filename)
        get_as instructor, :get_file, params: { course_id: course.id,
                                                id: submission.id,
                                                submission_file_id: submission_file.id }
        expect(JSON.parse(response.body)['type']).to eq('image')
      end
    end
    describe 'when the file is a pdf' do
      let(:files) { [file5] }
      it 'should return the file type' do
        submission_file = submission.submission_files.find_by(filename: file5.original_filename)
        get_as instructor, :get_file, params: { course_id: course.id,
                                                id: submission.id,
                                                submission_file_id: submission_file.id }
        expect(JSON.parse(response.body)['type']).to eq('pdf')
      end
    end
    describe 'when the file is missing' do
      let(:files) { [file1] }
      it 'should return an unknown file type' do
        submission_file = submission.submission_files.find_by(filename: file1.original_filename)
        allow_any_instance_of(MemoryRevision).to receive(:files_at_path).and_return({})
        get_as instructor, :get_file, params: { course_id: course.id,
                                                id: submission.id,
                                                submission_file_id: submission_file.id }
        expect(JSON.parse(response.body)['type']).to eq('unknown')
      end
    end
  end
  describe '#download_summary' do
    let(:assignment) { create :assignment }
    let!(:groupings) { create_list :grouping_with_inviter_and_submission, 2, assignment: assignment }
    let(:returned_group_names) do
      header = nil
      groups = []
      MarkusCsv.parse(response.body) do |line|
        if header.nil?
          header = line
        else
          groups << header.zip(line).to_h[I18n.t('activerecord.models.group.one')]
        end
      end
      groups
    end
    subject { get_as role, 'download_summary', params: { course_id: course.id, assignment_id: assignment.id } }
    context 'an instructor' do
      before { subject }
      let(:role) { create :instructor }
      it 'should be allowed' do
        expect(response).to have_http_status(200)
      end
      it 'should download submission info for all groupings' do
        expect(returned_group_names).to contain_exactly(*groupings.map { |g| g.group.group_name })
      end
      it 'should not include hidden values' do
        header = nil
        MarkusCsv.parse(response.body) { |line| header ||= line }
        hidden = header.select { |h| h.start_with?('_') || h.end_with?('_id') }
        expect(hidden).to be_empty
      end
    end
    context 'a grader' do
      let(:role) { create :ta }
      it 'should be allowed' do
        subject
        expect(response).to have_http_status(200)
      end
      context 'who has not been assigned any groupings' do
        it 'should download an empty csv' do
          subject
          expect(returned_group_names).to be_empty
        end
      end
      context 'who has been assigned a single grouping' do
        before { create :ta_membership, role: role, grouping: groupings.first }
        it 'should download the group info for the assigned group' do
          subject
          expect(returned_group_names).to contain_exactly(groupings.first.group.group_name)
        end
      end
      context 'who has been assigned all groupings' do
        before { groupings.each { |g| create :ta_membership, role: role, grouping: g } }
        it 'should download the group info for the assigned group' do
          subject
          expect(returned_group_names).to contain_exactly(*groupings.map { |g| g.group.group_name })
        end
        it 'should not include hidden values' do
          subject
          header = nil
          MarkusCsv.parse(response.body) { |line| header ||= line }
          hidden = header.select { |h| h.start_with?('_') || h.end_with?('_id') }
          expect(hidden).to be_empty
        end
      end
    end
    context 'a student' do
      before { subject }
      let(:role) { create :student }
      it 'should be forbidden' do
        expect(response).to have_http_status(403)
      end
    end
  end
end
