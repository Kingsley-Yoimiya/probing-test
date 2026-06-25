"""Monkey-patch Megatron training to emit probing phase spans."""

from __future__ import annotations

import logging
import types

logger = logging.getLogger(__name__)
_INSTALLED = False


def _patch_pipeline_phases() -> None:
    import megatron.core.pipeline_parallel.schedules as schedules

    if getattr(schedules, "_probing_sched_patched", False):
        return

    orig_forward = schedules.forward_step
    orig_backward = schedules.backward_step

    def forward_step(*args, **kwargs):
        from probing.tracing.phases import FORWARD, hook_enter, hook_exit

        hook_enter(FORWARD)
        try:
            return orig_forward(*args, **kwargs)
        finally:
            hook_exit(FORWARD)

    def backward_step(*args, **kwargs):
        from probing.tracing.phases import BACKWARD, hook_enter, hook_exit

        hook_enter(BACKWARD)
        try:
            return orig_backward(*args, **kwargs)
        finally:
            hook_exit(BACKWARD)

    schedules.forward_step = forward_step
    schedules.backward_step = backward_step
    schedules._probing_sched_patched = True


def _wrap_optimizer_step(optimizer) -> None:
    if optimizer is None or getattr(optimizer, "_probing_step_wrapped", False):
        return

    chained = getattr(optimizer, "chained_optimizers", None)
    if chained:
        for inner in chained:
            _wrap_optimizer_step(inner)

    from probing.tracing.phases import OPTIMIZER, hook_enter, hook_exit

    orig_step = optimizer.step

    def step(*args, **kwargs):
        hook_enter(OPTIMIZER)
        try:
            return orig_step(*args, **kwargs)
        finally:
            hook_exit(OPTIMIZER)

    optimizer.step = types.MethodType(step, optimizer)
    optimizer._probing_step_wrapped = True


def _attach_probing(_model, optimizer, _opt_param_scheduler) -> None:
    try:
        import probing
    except ImportError:
        return
    if not probing.is_enabled():
        return

    from megatron.core.num_microbatches_calculator import get_num_microbatches

    try:
        nmb = get_num_microbatches()
        if nmb and nmb > 1:
            probing.step(micro_batches=int(nmb))
    except Exception:
        pass

    _patch_pipeline_phases()
    _wrap_optimizer_step(optimizer)

    try:
        from megatron.training import print_rank_0

        print_rank_0("[probing] Megatron phase spans enabled (pipeline + optimizer)")
    except Exception:
        pass


def install() -> None:
    global _INSTALLED
    if _INSTALLED:
        return
    import megatron.training.training as mt

    original = mt.setup_model_and_optimizer

    def setup_model_and_optimizer(*args, **kwargs):
        result = original(*args, **kwargs)
        try:
            model, opt, sched = result
            _attach_probing(model, opt, sched)
        except Exception as exc:
            logger.warning("probing attach failed: %s", exc)
        return result

    mt.setup_model_and_optimizer = setup_model_and_optimizer
    _INSTALLED = True
