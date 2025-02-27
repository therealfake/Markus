class ResultsController < ApplicationController
  before_action { authorize! }
  after_action :update_remark_request_count,
               only: [:update_remark_request, :cancel_remark_request,
                      :set_released_to_students]

  authorize :from_codeviewer, through: :from_codeviewer_param
  authorize :select_file, through: :select_file

  content_security_policy only: [:edit, :view_marks] do |p|
    # required because heic2any uses libheif which calls
    # eval (javascript) and creates an image as a blob.
    # TODO: remove this when possible
    p.script_src :self, "'strict-dynamic'", "'unsafe-eval'"
    p.img_src :self, :blob
    # required because MathJax dynamically changes
    # style. # TODO: remove this when possible
    p.style_src :self, "'unsafe-inline'"
    p.frame_src(*SubmissionsController::PERMITTED_IFRAME_SRC)
  end

  def show
    respond_to do |format|
      format.json do
        result = record
        submission = result.submission
        assignment = submission.assignment
        remark_submitted = submission.remark_submitted?
        original_result = remark_submitted ? submission.get_original_result : nil
        is_review = result.is_a_review?
        is_reviewer = current_role.student? && current_role.is_reviewer_for?(assignment.pr_assignment, result)

        if current_role.student? && !current_role.is_reviewer_for?(assignment.pr_assignment, result)
          grouping = current_role.accepted_grouping_for(assignment.id)
          if submission.grouping_id != grouping&.id ||
              !result.released_to_students?
            head :forbidden
            return
          end
        else
          grouping = submission.grouping
        end

        data = {
          grouping_id: is_reviewer ? nil : submission.grouping_id,
          marking_state: result.marking_state,
          released_to_students: result.released_to_students,
          detailed_annotations: current_role.instructor? || current_role.ta? || is_reviewer,
          revision_identifier: submission.revision_identifier,
          instructor_run: true,
          allow_remarks: assignment.allow_remarks,
          remark_submitted: remark_submitted,
          remark_request_text: submission.remark_request,
          remark_request_timestamp: submission.remark_request_timestamp,
          assignment_remark_message: assignment.remark_message,
          remark_due_date: assignment.remark_due_date,
          past_remark_due_date: assignment.past_remark_due_date?,
          is_reviewer: is_reviewer,
          student_view: current_role.student? && !is_reviewer
        }
        if original_result.nil?
          data[:overall_comment] = result.overall_comment
          data[:remark_overall_comment] = nil
        else
          data[:overall_comment] = original_result.overall_comment
          data[:remark_overall_comment] = result.overall_comment
        end
        if is_reviewer
          data[:feedback_files] = []
        else
          data[:feedback_files] = submission.feedback_files.where(test_group_result_id: nil).map do |f|
            { id: f.id, filename: f.filename, type: FileHelper.get_file_type(f.filename) }
          end
        end

        if assignment.enable_test
          authorized = allowed_to?(:run_tests?, current_role, context: { assignment: assignment,
                                                                         grouping: grouping,
                                                                         submission: submission })
          data[:enable_test] = true
          data[:can_run_tests] = authorized
        else
          data[:enable_test] = false
          data[:can_run_tests] = false
        end

        data[:can_release] = allowed_to?(:manage_assessments?, current_role)

        # Submission files
        file_data = submission.submission_files.order(:path, :filename).pluck_to_hash(:id, :filename, :path)
        file_data.reject! { |f| Repository.get_class.internal_file_names.include? f[:filename] }
        data[:submission_files] = file_data

        # Annotations
        all_annotations = result.annotations
                                .includes(:submission_file, :creator,
                                          annotation_text: :annotation_category)
        if remark_submitted
          all_annotations += original_result.annotations
                                            .includes(:submission_file, :creator,
                                                      annotation_text: :annotation_category)
        end

        data[:annotations] = all_annotations.map do |annotation|
          annotation.get_data(include_creator: current_role.instructor? || current_role.ta?)
        end

        # Annotation categories
        if current_role.instructor? || current_role.ta?
          annotation_categories = AnnotationCategory.visible_categories(assignment, current_role)
                                                    .includes(:annotation_texts)
          data[:annotation_categories] = annotation_categories.map do |category|
            name_extension = category.flexible_criterion_id.nil? ? '' : " [#{category.flexible_criterion.name}]"
            {
              id: category.id,
              annotation_category_name: category.annotation_category_name + name_extension,
              texts: category.annotation_texts.map do |text|
                {
                  id: text.id,
                  content: text.content,
                  deduction: text.deduction
                }
              end,
              flexible_criterion_id: category.flexible_criterion_id
            }
          end
          data[:notes_count] = submission.grouping.notes.count
          data[:num_marked] = assignment.get_num_marked(current_role.instructor? ? nil : current_role.id)
          data[:num_collected] = assignment.get_num_collected(current_role.instructor? ? nil : current_role.id)
          if current_role.ta? && assignment.anonymize_groups
            data[:group_name] = "#{Group.model_name.human} #{submission.grouping.id}"
            data[:members] = []
          else
            data[:group_name] = submission.grouping.group.group_name
            data[:members] = submission.grouping.accepted_students.map(&:user_name)
          end
        elsif is_reviewer
          reviewer_group = current_role.grouping_for(assignment.pr_assignment.id)
          data[:num_marked] = PeerReview.get_num_marked(reviewer_group)
          data[:num_collected] = PeerReview.get_num_collected(reviewer_group)
          data[:group_name] = PeerReview.model_name.human
          data[:members] = []
        end

        # Marks
        fields = [:id, :name, :description, :position, :max_mark]
        marks_map = [CheckboxCriterion, FlexibleCriterion, RubricCriterion].flat_map do |klass|
          criteria = klass.where(assessment_id: is_review ? assignment.pr_assignment.id : assignment.id,
                                 ta_visible: !is_review,
                                 peer_visible: is_review)
          criteria_info = criteria.pluck_to_hash(*fields)
          marks_info = criteria.joins(:marks)
                               .where('marks.result_id': result.id)
                               .pluck_to_hash(*fields,
                                              'marks.mark AS mark',
                                              'marks.override AS override',
                                              'criteria.bonus AS bonus')
                               .group_by { |h| h[:id] }
          # adds a criterion type to each of the marks info hashes
          criteria_info.map do |cr|
            info = marks_info[cr[:id]]&.first || cr.merge(mark: nil)

            # adds a levels field to the marks info hash with the same rubric criterion id
            if klass == RubricCriterion
              info[:levels] = Level.where(criterion_id: cr[:id])
                                   .order(:mark)
                                   .pluck_to_hash(:name, :description, :mark)
            end
            info.merge(criterion_type: klass.name)
          end
        end
        marks_map.sort! { |a, b| a[:position] <=> b[:position] }

        if original_result.nil?
          old_marks = {}
        else
          old_marks = original_result.mark_hash
        end

        if assignment.assign_graders_to_criteria && current_role.ta?
          assigned_criteria = current_role.criterion_ta_associations
                                          .where(assessment_id: assignment.id)
                                          .pluck(:criterion_id)
          if assignment.hide_unassigned_criteria
            marks_map = marks_map.select { |m| assigned_criteria.include? m[:id] }
            old_marks = old_marks.select { |m| assigned_criteria.include? m }
          else
            marks_map = marks_map.partition { |m| assigned_criteria.include? m[:id] }
                                 .flatten
          end
        else
          assigned_criteria = nil
        end

        data[:assigned_criteria] = assigned_criteria
        data[:marks] = marks_map

        data[:old_marks] = old_marks

        # Extra marks
        data[:extra_marks] = result.extra_marks
                                   .pluck_to_hash(:id, :description, :extra_mark, :unit)

        # Grace token deductions
        if is_reviewer || (current_role.ta? && assignment.anonymize_groups)
          data[:grace_token_deductions] = []
        elsif current_role.student?
          data[:grace_token_deductions] =
            submission.grouping
                      .grace_period_deductions
                      .joins(membership: [role: :end_user])
                      .where('users.user_name': current_user.user_name)
                      .pluck_to_hash(:id, :deduction, 'users.user_name', 'users.display_name')
        else
          data[:grace_token_deductions] =
            submission.grouping
                      .grace_period_deductions
                      .joins(membership: [role: :end_user])
                      .pluck_to_hash(:id, :deduction, 'users.user_name', 'users.display_name')
        end

        # Totals
        if result.is_a_review?
          data[:assignment_max_mark] = assignment.pr_assignment.max_mark(:peer_visible)
        else
          data[:assignment_max_mark] = assignment.max_mark
        end
        data[:total] = marks_map.map { |h| h['mark'] }
        data[:old_total] = old_marks.values_at(:mark).compact.sum

        # Tags
        all_tags = assignment.tags.pluck_to_hash(:id, :name)
        data[:current_tags] = submission.grouping.tags.pluck_to_hash(:id, :name)
        data[:available_tags] = all_tags - data[:current_tags]

        render json: data
      end
    end
  end

  def edit
    @host = Rails.application.config.action_controller.relative_url_root
    @result = record
    @submission = @result.submission
    @grouping = @submission.grouping
    @assignment = @grouping.assignment

    # authorization
    allowed = allowance_to(:run_tests?, current_role, context: { assignment: @assignment,
                                                                 grouping: @grouping,
                                                                 submission: @submission })
    flash_allowance(:notice, allowed) if @assignment.enable_test
    @authorized = allowed.value

    m_logger = MarkusLogger.instance
    m_logger.log("User '#{current_role.user_name}' viewed submission (id: #{@submission.id})" \
                 "of assignment '#{@assignment.short_identifier}' for group '" \
                 "#{@grouping.group.group_name}'")

    # Check whether this group made a submission after the final deadline.
    if @grouping.submitted_after_collection_date?
      flash_message(:warning,
                    t('results.late_submission_warning_html',
                      url: repo_browser_course_assignment_submissions_path(@current_course, @assignment,
                                                                           grouping_id: @grouping.id)))
    end

    # Check whether marks have been released.
    if @result.released_to_students
      flash_message(:notice, t('results.marks_released'))
    end

    render layout: 'result_content'
  end

  def run_tests
    submission = record.submission
    @current_job = AutotestRunJob.perform_later(request.protocol + request.host_with_port,
                                                current_role.id,
                                                submission.assignment.id,
                                                [submission.grouping.group_id])
    session[:job_id] = @current_job.job_id
    flash_message(:success, I18n.t('automated_tests.tests_running'))
  end

  ##  Tag Methods  ##
  def add_tag
    # TODO: this should be in the grouping or tag controller
    result = record
    tag = Tag.find(params[:tag_id])
    result.submission.grouping.tags << tag
    head :ok
  end

  def remove_tag
    # TODO: this should be in the grouping or tag controller
    result = record
    tag = Tag.find(params[:tag_id])
    result.submission.grouping.tags.destroy(tag)
    head :ok
  end

  def next_grouping
    result = record
    grouping = result.submission.grouping
    assignment = grouping.assignment

    if current_role.ta?
      groupings = current_role.groupings
                              .where(assignment: assignment)
                              .joins(:group)
                              .order('group_name')
      if params[:direction] == '1'
        next_grouping = groupings.where('group_name > ?', grouping.group.group_name).first
      else
        next_grouping = groupings.where('group_name < ?', grouping.group.group_name).last
      end
      next_result = next_grouping&.current_result
    elsif result.is_a_review? && current_role.is_reviewer_for?(assignment.pr_assignment, result)
      assigned_prs = current_role.grouping_for(assignment.pr_assignment.id).peer_reviews_to_others
      if params[:direction] == '1'
        next_grouping = assigned_prs.where('peer_reviews.id > ?', result.peer_review_id).first
      else
        next_grouping = assigned_prs.where('peer_reviews.id < ?', result.peer_review_id).last
      end
      next_result = Result.find(next_grouping.result_id)
    else
      groupings = assignment.groupings.joins(:group).order('group_name')
      if params[:direction] == '1'
        next_grouping = groupings.where('group_name > ?', grouping.group.group_name).first
      else
        next_grouping = groupings.where('group_name < ?', grouping.group.group_name).last
      end
      next_result = next_grouping&.current_result
    end

    render json: { next_result: next_result, next_grouping: next_grouping }
  end

  def set_released_to_students
    @result = record
    released_to_students = !@result.released_to_students
    @result.released_to_students = released_to_students
    if @result.save
      m_logger = MarkusLogger.instance
      assignment = @result.submission.assignment
      if released_to_students
        m_logger.log("Marks released for assignment '#{assignment.short_identifier}', ID: '"\
                     "#{assignment.id}' (for 1 group).")
      else
        m_logger.log("Marks unreleased for assignment '#{assignment.short_identifier}', ID: '"\
                     "#{assignment.id}' (for 1 group).")
      end
    end
    head :ok
  end

  # Toggles the marking state
  def toggle_marking_state
    @result = record
    @old_marking_state = @result.marking_state

    if @result.marking_state == Result::MARKING_STATES[:complete]
      @result.marking_state = Result::MARKING_STATES[:incomplete]
    else
      @result.marking_state = Result::MARKING_STATES[:complete]
    end

    if @result.save
      head :ok
    else # Failed to pass validations
      # Show error message
      render 'results/marker/show_result_error'
    end
  end

  def download
    # TODO: move this to the submissions controller
    if params[:download_zip_button]
      download_zip
      return
    end

    file = select_file
    if params[:show_in_browser] == 'true' && (file.is_pynb? || file.is_rmd?)
      redirect_to notebook_content_course_assignment_submissions_url(current_course,
                                                                     record.submission.grouping.assignment,
                                                                     select_file_id: params[:select_file_id])
      return
    end

    begin
      if params[:include_annotations] == 'true' && !file.is_supported_image?
        file_contents = file.retrieve_file(include_annotations: true)
      else
        file_contents = file.retrieve_file
      end
    rescue StandardError => e
      flash_message(:error, e.message)
      redirect_to edit_course_result_path(current_course, record)
      return
    end
    filename = file.filename
    # Display the file in the page if it is an image/pdf, and download button
    # was not explicitly pressed
    if file.is_supported_image? && !params[:show_in_browser].nil?
      send_data file_contents, type: 'image', disposition: 'inline',
                               filename: filename
    else
      send_data_download file_contents, filename: filename
    end
  end

  def download_zip
    # TODO: move this to the submissions controller
    submission = record.submission
    if submission.revision_identifier.nil?
      render plain: t('submissions.no_files_available')
      return
    end

    grouping = submission.grouping
    assignment = grouping.assignment
    revision_identifier = submission.revision_identifier
    repo_folder = assignment.repository_folder
    zip_name = "#{repo_folder}-#{grouping.group.repo_name}"

    zip_path = if params[:include_annotations] == 'true'
                 "tmp/#{assignment.short_identifier}_" \
                   "#{grouping.group.group_name}_r#{revision_identifier}_ann.zip"
               else
                 "tmp/#{assignment.short_identifier}_" \
                   "#{grouping.group.group_name}_r#{revision_identifier}.zip"
               end

    files = submission.submission_files
    Zip::File.open(zip_path, create: true) do |zip_file|
      grouping.access_repo do |repo|
        revision = repo.get_revision(revision_identifier)
        repo.send_tree_to_zip(assignment.repository_folder, zip_file, zip_name, revision) do |file|
          submission_file = files.find_by(filename: file.name, path: file.path)
          submission_file&.retrieve_file(
            include_annotations: params[:include_annotations] == 'true' && !submission_file.is_supported_image?
          )
        end
      end
    end
    # Send the Zip file
    send_file zip_path, disposition: 'inline',
                        filename: zip_name + '.zip'
  end

  def get_annotations
    result = record
    all_annots = result.annotations.includes(:submission_file, :creator,
                                             { annotation_text: :annotation_category })
    if result.submission.remark_submitted?
      all_annots += result.submission.get_original_result.annotations
    end

    annotation_data = all_annots.map do |annotation|
      annotation.get_data(include_creator: current_role.instructor? || current_role.ta?)
    end

    render json: annotation_data
  end

  def update_mark
    result = record
    submission = result.submission
    group = submission.grouping.group
    assignment = submission.grouping.assignment
    mark_value = params[:mark].blank? ? nil : params[:mark].to_f

    # make this operation atomic (more or less) so that concurrent requests won't make duplicate values
    result_mark = Mark.transaction { result.marks.order(:id).find_or_create_by(criterion_id: params[:criterion_id]) }
    unless result_mark.valid?
      # In case the transaction above doesn't do its job, this will clean up any duplicate marks in the database
      marks = result.marks.where(criterion_id: params[:criterion_id])
      marks.where.not(id: result_mark.id).destroy_all if marks.count > 1
      result_mark.save
    end

    m_logger = MarkusLogger.instance

    if result_mark.update(mark: mark_value, override: !(mark_value.nil? && result_mark.deductive_annotations_absent?))

      m_logger.log("User '#{current_role.user_name}' updated mark for " \
                   "submission (id: #{submission.id}) of " \
                   "assignment #{assignment.short_identifier} for " \
                   "group #{group.group_name}.",
                   MarkusLogger::INFO)
      if current_role.ta?
        num_marked = assignment.get_num_marked(current_role.id)
      else
        num_marked = assignment.get_num_marked(nil)
      end
      render json: {
        num_marked: num_marked,
        mark: result_mark.reload.mark,
        mark_override: result_mark.override,
        subtotal: result.get_subtotal,
        total: result.get_total_mark
      }
    else
      m_logger.log('Error while trying to update mark of submission. ' \
                   "User: #{current_role.user_name}, " \
                   "Submission id: #{submission.id}, " \
                   "Assignment: #{assignment.short_identifier}, " \
                   "Group: #{group.group_name}.",
                   MarkusLogger::ERROR)
      render json: result_mark.errors.full_messages.join, status: :bad_request
    end
  end

  def revert_to_automatic_deductions
    result = record
    criterion = Criterion.find_by!(id: params[:criterion_id], type: 'FlexibleCriterion')
    result_mark = result.marks.find_or_create_by(criterion: criterion)

    result_mark.update!(override: false)

    if current_role.ta?
      num_marked = result.submission.grouping.assignment.get_num_marked(current_role.id)
    else
      num_marked = result.submission.grouping.assignment.get_num_marked(nil)
    end
    render json: {
      num_marked: num_marked,
      mark: result_mark.reload.mark,
      subtotal: result.get_subtotal,
      total: result.get_total_mark
    }
  end

  def view_marks
    result_from_id = record
    @assignment = result_from_id.submission.grouping.assignment
    @assignment = @assignment.is_peer_review? ? @assignment.parent_assignment : @assignment
    is_review = result_from_id.is_a_review? || result_from_id.is_review_for?(current_role, @assignment)

    if current_role.student?
      @grouping = current_role.accepted_grouping_for(@assignment.id)
      if @grouping.nil?
        redirect_to course_assignment_path(current_course, @assignment)
        return
      end
      unless is_review || @grouping.has_submission?
        render 'results/student/no_submission'
        return
      end
      @submission = @grouping.current_submission_used
      unless is_review || @submission.has_result?
        render 'results/student/no_result'
        return
      end
      if result_from_id.is_a_review?
        @result = result_from_id
      else
        unless @submission
          render 'results/student/no_result'
          return
        end
        @result = @submission.get_original_result
      end
    else
      @result = result_from_id
      @submission = @result.submission
      @grouping = @submission.grouping
    end

    # TODO: Review the various code flows, the duplicate checks are a temporary stop-gap
    if @grouping.nil?
      redirect_to course_assignment_path(current_course, @assignment)
      return
    end
    unless is_review || @grouping.has_submission?
      render 'results/student/no_submission'
      return
    end
    unless is_review || @submission.has_result?
      render 'results/student/no_result'
      return
    end

    if is_review
      if current_role.student?
        @prs = @grouping.peer_reviews.where(results: { released_to_students: true })
      else
        @reviewer = Grouping.find(params[:reviewer_grouping_id])
        @prs = @reviewer.peer_reviews_to_others
      end

      @current_pr = PeerReview.find_by(result_id: @result.id)
      @current_pr_result = @current_pr.result
      @current_group_name = @current_pr_result.submission.grouping.group.group_name
    end

    @old_result = nil
    if !is_review && @submission.remark_submitted?
      @old_result = @result
      @result = @submission.remark_result
      # Check if remark request has been submitted but not released yet
      if !@result.remark_request_submitted_at.nil? && !@result.released_to_students
        render 'results/student/no_remark_result'
        return
      end
    end
    unless is_review || @result.released_to_students
      render 'results/student/no_result'
      return
    end

    @annotation_categories = @assignment.annotation_categories
    @group = @grouping.group
    @files = @submission.submission_files.sort do |a, b|
      File.join(a.path, a.filename) <=> File.join(b.path, b.filename)
    end
    @feedback_files = @submission.feedback_files

    @host = Rails.application.config.action_controller.relative_url_root

    m_logger = MarkusLogger.instance
    m_logger.log("Student '#{current_role.user_name}' viewed results for assignment '#{@assignment.short_identifier}'.")
  end

  def add_extra_mark
    @result = record
    @extra_mark = @result.extra_marks.build(extra_mark_params.merge(unit: ExtraMark::POINTS))
    if @extra_mark.save
      # need to re-calculate total mark
      @result.update_total_mark
      head :ok
    else
      head :bad_request
    end
  end

  def remove_extra_mark
    result = record
    extra_mark = result.extra_marks.find(params[:extra_mark_id])

    extra_mark.destroy
    result.update_total_mark
    head :ok
  end

  def update_overall_comment
    record.update(overall_comment: params[:result][:overall_comment])
    head :ok
  end

  def update_remark_request
    @submission = Submission.find(params[:submission_id])
    @assignment = @submission.grouping.assignment
    if @assignment.past_remark_due_date?
      head :bad_request
    else
      @submission.update(
        remark_request: params[:submission][:remark_request],
        remark_request_timestamp: Time.current
      )
      if params[:save]
        head :ok
      elsif params[:submit]
        unless @submission.remark_result
          @submission.make_remark_result
          @submission.non_pr_results.reload
        end
        @submission.remark_result.update(marking_state: Result::MARKING_STATES[:incomplete])
        @submission.get_original_result.update(released_to_students: false)
        render js: 'location.reload();'
      else
        head :bad_request
      end
    end
  end

  # Allows student to cancel a remark request.
  def cancel_remark_request
    submission = Submission.find(params[:submission_id])

    submission.remark_result.destroy
    submission.get_original_result.update(released_to_students: true)

    redirect_to controller: 'results',
                action: 'view_marks',
                course_id: current_course.id,
                id: submission.get_original_result.id
  end

  def delete_grace_period_deduction
    result = record
    grace_deduction = result.submission.grouping.grace_period_deductions.find(params[:deduction_id])
    grace_deduction.destroy
    head :ok
  end

  def get_test_runs_instructors
    submission = record.submission
    test_runs = submission.grouping.test_runs_instructors(submission)
    test_runs.each do |test_run|
      test_run['test_runs.created_at'] = I18n.l(test_run['test_runs.created_at'])
    end
    render json: test_runs.group_by { |t| t['test_runs.id'] }
  end

  def get_test_runs_instructors_released
    submission = record.submission
    test_runs = submission.grouping.test_runs_instructors_released(submission)
    test_runs.each do |test_run|
      test_run['test_runs.created_at'] = I18n.l(test_run['test_runs.created_at'])
    end
    render json: test_runs.group_by { |t| t['test_runs.id'] }
  end

  private

  def update_remark_request_count
    if record
      record.submission.grouping.assignment.update_remark_request_count
    else
      Submission.find(params[:submission_id]).grouping.assignment.update_remark_request_count
    end
  end

  def from_codeviewer_param
    params[:from_codeviewer] == 'true'
  end

  def select_file
    params[:select_file_id] && SubmissionFile.find_by(id: params[:select_file_id])
  end

  def extra_mark_params
    params.require(:extra_mark).permit(:result,
                                       :description,
                                       :extra_mark)
  end
end
