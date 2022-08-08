# frozen_string_literal: true

require "test_helper"
require "sidekiq"
require "sidekiq/testing"

# rubocop:disable Lint/ConstantDefinitionInBlock
class Cases::ActiveKiq::EdgeCases < ActiveSupport::TestCase
  def before_setup
    super()
    AcidicJob::Run.delete_all
    Notification.delete_all
    Performance.reset!
    Sidekiq::Queues.clear_all
    Sidekiq.redis(&:flushdb)
  end
  
  # :nocov:
  def perform_enqueued_jobs
    yield
    Sidekiq::Worker.drain_all
  end
  # :nocov:
  
  test "calling `with_acidic_workflow` without a block raises `MissingWorkflowBlock`" do
    class WithoutBlock < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow
      end
    end

    assert_raises AcidicJob::MissingWorkflowBlock do
      WithoutBlock.perform_now
    end
  end

  test "calling `with_acidic_workflow` with a block without steps raises `NoDefinedSteps`" do
    class WithoutSteps < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow {} # rubocop:disable Lint/EmptyBlock
      end
    end

    assert_raises AcidicJob::NoDefinedSteps do
      WithoutSteps.perform_now
    end
  end

  test "calling `with_acidic_workflow` twice raises `RedefiningWorkflow`" do
    class DoubleWorkflow < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow do |workflow|
          workflow.step :do_something
        end

        with_acidic_workflow {} # rubocop:disable Lint/EmptyBlock
      end

      def do_something; end
    end

    assert_raises AcidicJob::RedefiningWorkflow do
      DoubleWorkflow.perform_now
    end
  end

  test "calling `with_acidic_workflow` with an undefined step method without `awaits` raises `UndefinedStepMethod`" do
    class UndefinedStep < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow do |workflow|
          workflow.step :no_op
        end
      end
    end

    assert_raises AcidicJob::UndefinedStepMethod do
      UndefinedStep.perform_now
    end
  end

  test "calling `with_acidic_workflow` with `persisting` unserializable value throws `UnserializableValue` error" do
    class UnpersistableValue < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow persisting: { key: -> { :some_proc } } do |workflow|
          workflow.step :do_something
        end
      end

      def do_something; end
    end

    assert_raises AcidicJob::UnserializableValue do
      UnpersistableValue.perform_now
    end
  end

  test "`persisting` an attribute with a pre-defined reader is handled smoothly" do
    class PersistingAttrReader < AcidicJob::ActiveKiq
      attr_reader :attr

      def perform
        with_acidic_workflow persisting: { attr: nil } do |workflow|
          workflow.step :do_something
        end
      end

      def do_something
        Performance.performed!
      end
    end

    PersistingAttrReader.perform_now
    run = AcidicJob::Run.find_by(job_class: [self.class.name, "PersistingAttrReader"].join("::"))
    assert_equal "FINISHED", run.recovery_point
    assert_nil run.error_object

    assert_equal 1, Performance.performances
  end

  test "step method that takes an argument throws `TooManyParametersForStepMethod` error" do
    class StepMethodTakesArg < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow do |workflow|
          workflow.step :do_something
        end
      end

      def do_something(_arg); end
    end

    assert_raises AcidicJob::TooManyParametersForStepMethod do
      StepMethodTakesArg.perform_now
    end
  end

  test "invalid worker throws `UnknownJobAdapter` error" do
    assert_raises AcidicJob::UnknownJobAdapter do
      Class.new do
        include AcidicJob::Mixin
      end
    end
  end

  test "unknown `awaits` method throws `UnknownAwaitedJob` error" do
    class ErrAwaitsUnknown < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow do |workflow|
          workflow.step :await_step, awaits: :undefined_method
          workflow.step :do_something
        end
      end

      # :nocov:
      def do_something
        Performance.performed!
      end
      # :nocov:
    end

    assert_raises AcidicJob::UnknownAwaitedJob do
      ErrAwaitsUnknown.perform_now
    end

    assert_equal 0, Performance.performances
  end

  test "invalid `awaits` value throws `UnknownAwaitedJob` error" do
    class ErrAwaitsInvalid < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow do |workflow|
          workflow.step :await_step, awaits: 123
          workflow.step :do_something
        end
      end

      # :nocov:
      def do_something
        Performance.performed!
      end
      # :nocov:
    end

    assert_raises AcidicJob::UnknownAwaitedJob do
      ErrAwaitsInvalid.perform_now
    end

    assert_equal 0, Performance.performances
  end

  test "nil `awaits` value is ignored and workflow continues" do
    class ErrAwaitsNil < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow do |workflow|
          workflow.step :await_step, awaits: [nil]
          workflow.step :do_something
        end
      end

      def do_something
        Performance.performed!
      end
    end

    ErrAwaitsNil.perform_now

    assert_equal 1, Performance.performances
  end

  test "invalid workflow in run record raises `UnknownRecoveryPoint`" do
    class InvalidWorkflowRun < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow do |workflow|
          workflow.step :do_something
        end
      end

      # :nocov:
      def do_something
        Performance.performed!
      end
      # :nocov:
    end

    run = AcidicJob::Run.create!(
      idempotency_key: "12a345bc-67e8-90f1-23g4-5h6i7jk8l901",
      serialized_job: {
        "job_class" => "InvalidWorkflowRun",
        "job_id" => "12a345bc-67e8-90f1-23g4-5h6i7jk8l901",
        "provider_job_id" => nil,
        "queue_name" => "default",
        "priority" => nil,
        "arguments" => [],
        "executions" => 1,
        "exception_executions" => {},
        "locale" => "en",
        "timezone" => "UTC",
        "enqueued_at" => ""
      },
      job_class: "InvalidWorkflowRun",
      staged: false,
      last_run_at: Time.current,
      recovery_point: "OLD_RECOVERY_POINT_FROM_BEFORE_A_NEW_RELEASE",
      workflow: {
        "do_something" => { "does" => "do_something", "awaits" => [], "for_each" => nil, "then" => "FINISHED" }
      }
    )
    AcidicJob::Run.stub(:find_by, ->(*) { run }) do
      assert_raises AcidicJob::UnknownRecoveryPoint do
        InvalidWorkflowRun.perform_now
      end
    end
    assert_equal 0, Performance.performances
  end

  test "rescued error in `perform` doesn't prevent `Run#error_object` from being stored" do
    class ErrorAndRescueInPerform < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow do |workflow|
          workflow.step :do_something
        end
      rescue CustomErrorForTesting
        true
      end

      def do_something
        raise CustomErrorForTesting
      end
    end

    result = ErrorAndRescueInPerform.perform_now
    assert_equal result, true
    assert_equal 1, AcidicJob::Run.count
    run = AcidicJob::Run.find_by(job_class: [self.class.name, "ErrorAndRescueInPerform"].join("::"))
    assert_equal CustomErrorForTesting, run.error_object.class
  end

  test "run with unknown `recovery_point` value throws `UnknownRecoveryPoint` error when processed" do
    class ErrUnknownRecoveryPoint < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow do |workflow|
          workflow.step :step_one
        end
      end

      # :nocov:
      def step_one
        Performance.performed!
      end
      # :nocov:
    end

    run = AcidicJob::Run.create!(
      idempotency_key: "67b823ea-34f0-40a0-88d9-7e3b7ff9e769",
      serialized_job: {
        "job_class" => "ErrUnknownRecoveryPoint",
        "job_id" => "67b823ea-34f0-40a0-88d9-7e3b7ff9e769",
        "provider_job_id" => nil,
        "queue_name" => "default",
        "priority" => nil,
        "arguments" => [],
        "executions" => 1,
        "exception_executions" => {},
        "locale" => "en",
        "timezone" => "UTC",
        "enqueued_at" => ""
      },
      job_class: "ErrUnknownRecoveryPoint",
      last_run_at: Time.current,
      recovery_point: "unknown_step",
      workflow: {
        "step_one" => { "does" => "step_one", "awaits" => [], "for_each" => nil, "then" => "step_two" },
        "step_two" => { "does" => "step_two", "awaits" => [], "for_each" => nil, "then" => "FINISHED" }
      }
    )
    AcidicJob::Run.stub(:find_by, ->(*) { run }) do
      assert_raises AcidicJob::UnknownRecoveryPoint do
        ErrUnknownRecoveryPoint.perform_now
      end
    end
    assert_equal 0, Performance.performances
  end

  test "rollback while persisting ActiveRecord model in step method leaves no `attr_accessor` in Run model" do
    class RecordPersistingThenRollback < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow persisting: { notice: nil } do |workflow|
          workflow.step :do_something
        end
      end

      def do_something
        self.notice = Notification.create!(recipient_id: 1, recipient_type: "User")
        raise CustomErrorForTesting
      end
    end

    assert_raises CustomErrorForTesting do
      perform_enqueued_jobs do
        RecordPersistingThenRollback.perform_now
      end
    end

    assert_equal 1, AcidicJob::Run.count

    run = AcidicJob::Run.find_by(job_class: [self.class.name, "RecordPersistingThenRollback"].join("::"))
    assert_equal "do_something", run.recovery_point
    assert_equal 0, Notification.count
  end

  test "if error while trying to persist error in step method, swallow but log error" do
    class ErrorUnlockingAfterError < AcidicJob::ActiveKiq
      def perform
        with_acidic_workflow do |workflow|
          workflow.step :do_something
        end
      end

      def do_something
        raise CustomErrorForTesting
      end
    end

    run = AcidicJob::Run.create!(
      idempotency_key: "67b823ea-34f0-40a0-88d9-7e3b7ff9e769",
      serialized_job: {
        "job_class" => "ErrorUnlockingAfterError",
        "job_id" => "67b823ea-34f0-40a0-88d9-7e3b7ff9e769",
        "provider_job_id" => nil,
        "queue_name" => "default",
        "priority" => nil,
        "arguments" => [],
        "executions" => 1,
        "exception_executions" => {},
        "locale" => "en",
        "timezone" => "UTC",
        "enqueued_at" => ""
      },
      job_class: "ErrorUnlockingAfterError",
      last_run_at: Time.current,
      recovery_point: "do_something",
      workflow: {
        "do_something" => { "does" => "do_something", "awaits" => [], "for_each" => nil, "then" => "FINISHED" }
      }
    )
    # force an error occurring when AcidicJob is trying to unlock the run after a step method errors
    def run.store_error!(_error)
      raise RareErrorForTesting
    end
    AcidicJob::Run.stub(:find_by, ->(*) { run }) do
      assert_raises CustomErrorForTesting do
        ErrorUnlockingAfterError.perform_now
      end
    end

    run.reload
    assert !run.locked_at.nil?
    assert_equal false, run.succeeded?
  end
end
