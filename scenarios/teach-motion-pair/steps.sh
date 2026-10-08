# shellcheck shell=bash disable=SC2148
# teach-motion-pair — a DYNAMIC frame pair (docs/VERIFICATION.md §2).
#
# `pair <name> <A> <B> <metric> <floor>` passes when two shots of the same view DIFFER by at least
# the floor. Nothing is compared to a stored image, so nothing is blessed: use it when the outcome is
# visible but not repeatable frame for frame (an avatar walking, an effect playing).
# Shoot from the OBSERVER's display: the question is whether a sees what b did.
# Crop to where the event will be, not to the actor: b's avatar sways in its idle animation even when
# b stands still, so a crop on b differs with no event at all. The crop here is empty floor beside b
# that b walks into. The floor sits between the control's quiet value and the event's value.

boot a
login a
boot b                                                       # b after a: an idle client at its name box drowns
login b
hidechat a                                                   # the chat window would cover part of a's view
settle 5 "b's avatar finishes loading on a's screen"
shot a 10-a-still-1 "$P_CROP"                                # t0: the empty floor beside b
settle 3 "the control interval: nobody moves"
shot a 11-a-still-2 "$P_CROP"                                # t1: still nobody moved
still 10-a-still-1 11-a-still-2 0.005                        # control (hooks.sh): quiet frames match; measured 0.0014-0.0022
hold b d 3                                                   # b strafes right for 3 s, into the crop (b's input, b's display)
settle 2 "b's last position packet reaches a"
shot a 12-a-after-move "$P_CROP"                             # t2: b now stands in the crop
pair 12-a-sees-b-move 11-a-still-2 12-a-after-move RMSE 0.015  # the event: measured 0.038 (b as model) to 0.073 (placeholder)
pair 12-a-sees-b-move-t0 10-a-still-1 12-a-after-move RMSE 0.015 # also against t0 (and every shot is a pair input)
assert absent server "$RIG_TRIPWIRES"                        # no server-script error or crash in the whole run
