-- Decision 80a — system templates re-dressed with the blocks (cards + one button).
-- Authorised by Deanna, 21 Oct 2026 — template rows only, no data writes.
--
-- html_body is regenerated from composer markup through lib/email-body.mjs (the ONE
-- renderer), so a template's HTML matches what the composer produces. Subject and
-- (except retention) text_body are UNCHANGED — wording is preserved. Buttons use
-- {accent}/{accent_on}, filled per-studio by render_notification (80a). Per-studio
-- overrides (notification_templates_overrides) are untouched. studio_closure_notice
-- is a passthrough (the frame dresses it); free_booking_pending/not_confirmed are
-- not member-facing offer mail and keep their current body.

update notification_templates set html_body = '<p>Hi {first_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{when}{where_line}</div></td></tr></table>
{free_first_html}
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{manage_link}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Manage this booking</a></td></tr></table>
<p>If you can&#39;t make it, cancel in the app and the place goes to someone on the list.</p>
<p>{studio_name}</p>' where key = 'booking_confirmed';
update notification_templates set html_body = '<p>{class_name} on {day} is confirmed — see you at {time}.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{day} · {time}</div></td></tr></table>
<p>This is your free first class: if you can&#39;t make it, cancel before {cancel_deadline} or rebook another class, otherwise the free class is used.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{manage_link}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Manage your booking</a></td></tr></table>' where key = 'free_booking_confirmed';
update notification_templates set html_body = '<p>You&#39;re booked for {class_name}, {when}.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{when}</div></td></tr></table>
<p>We&#39;ll email you by {deadline_short} to confirm this class is going ahead. Nothing else to do.</p>' where key = 'flex_booking_pending';
update notification_templates set html_body = '<p>Your class is going ahead.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{when}</div></td></tr></table>
<p>See you {when} at {studio_name}.</p>' where key = 'flex_booking_confirmed';
update notification_templates set html_body = '<p>Your booking for {class_name} on {when} wasn&#39;t confirmed this time.</p>
<p>Your credit is back on your account and ready to use, so you can book another class straight away.</p>
{next_three_html}' where key = 'flex_booking_not_confirmed';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{when_short} · {when_time}{where_line}</div></td></tr></table>
<p>See you there.</p>
<p>{studio_name}</p>' where key = 'class_reminder';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>You&#39;re booked for {class_name} on {when}. A few things to make it easy:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{class_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">{when}</div></td></tr></table>
<p>• Wear something you can move in; we have everything else.<br>• Come about 10 minutes early so {instructor_first_name} can show you around.<br>• Water and a towel are handy.</p>
<p>See you there!</p>
<p>— {studio_name}</p>' where key = 'convert_before_class';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>We hope you enjoyed {class_name} with {instructor_first_name}. If it felt good, the easiest way to keep going is {offer_plan_name} — have a look whenever you&#39;re ready:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{offer_plan_name}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See your options</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'convert_after_class';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Ready for round two? {offer_plan_name} keeps it simple, and the schedule is here whenever you want to book:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{offer_plan_name}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book a class</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'convert_day3';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>No rush — your spot at {studio_name} is here when you want it. If you&#39;d like to come back, {offer_plan_name} is the easiest start:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{offer_plan_name}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Start here</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'convert_day7';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Today is the last day to start with {offer_plan_name} ({offer_price}) — it&#39;s open until {offer_ends}. If you&#39;ve been meaning to come back, this is the moment:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{offer_plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;color:#14170E;margin-top:8px">{offer_price}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Start now</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'convert_last_day';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>We had you down for {class_name} and didn&#39;t get to meet you — no problem at all. Your first class is still on us, so pick another time whenever suits:</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Pick a class</a></td></tr></table>
<p>— {studio_name}</p>' where key = 'convert_missed_you';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Your {plan_name} at {studio_name} ends on {expires_on}. Renewing keeps your spot and takes a moment:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Ends {expires_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Renew</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_renew_7';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>A quick reminder — your {plan_name} at {studio_name} ends tomorrow ({expires_on}). Renew to keep going without a gap:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Ends tomorrow — {expires_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Renew</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_renew_1';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Your {plan_name} at {studio_name} ends today. If you&#39;d like to keep your spot, renewing takes a moment:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Ends today — {expires_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Renew</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_renew_0';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Your {plan_name} ended a few days ago, but your spot is still here — no need to start over. Pick up where you left off whenever you&#39;re ready:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Pick up where you left off</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_lapsed_3';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>You have {credits_left} classes left at {studio_name}, and they expire on {expires_on}. Here is this week&#39;s schedule so none go to waste:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{credits_left} classes left</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Expire {expires_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See the schedule</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_credits_7';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Just a nudge — your {credits_left} remaining classes at {studio_name} expire on {expires_on}. Grab a spot this week:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{credits_left} classes left</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Expire {expires_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{schedule_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book a class</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_credits_2';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>It&#39;s been a few weeks since your last class at {studio_name}, and we&#39;d love to see you again. Come back whenever suits — your first step is here:</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Come back</a></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_winback_30';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Still thinking about coming back? Your spot at {studio_name} is here whenever you&#39;re ready — no pressure, no catch:</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Your spot is here</a></td></tr></table>
<p>— {studio_name}</p>' where key = 'keep_winback_60';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<p>Your {plan_name} at {studio_name} ends on {ends_on}. To keep going, renew for another period — it takes a moment and there is nothing to set up:</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Ends {ends_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{renew_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Renew</a></td></tr></table></div></td></tr></table>
<p>— {studio_name}</p>' where key = 'membership_expiring';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{credits} classes left</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Run out on {expires_on}</div></td></tr></table>
<p>That&#39;s a week from now, so there&#39;s still time to use them.</p>
<p>{studio_name}</p>' where key = 'credit_expiry';
update notification_templates set html_body = '<p>Hi {first_name},</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{product} ×{quantity}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Paid — ready to collect</div></td></tr></table>
<p>Pick it up at the front desk whenever suits you.</p>
<p>— {studio_name}</p>' where key = 'product_order_paid';
update notification_templates set text_body = 'Hi {first_name},

It was lovely having you in for {last_class} on {last_class_date} with {instructor_first}. We would love to see you again.

Your first class was on us — if you enjoyed it, {offer_plan_name} is a gentle way to keep going.

::: card
name: {offer_plan_name}
button: Have a look | {buy_url}
:::

Any questions, just reply to this email.

{studio_name}', html_body = '<p>Hi {first_name},</p>
<p>It was lovely having you in for {last_class} on {last_class_date} with {instructor_first}. We would love to see you again.</p>
<p>Your first class was on us — if you enjoyed it, {offer_plan_name} is a gentle way to keep going.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{offer_plan_name}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Have a look</a></td></tr></table></div></td></tr></table>
<p>Any questions, just reply to this email.</p>
<p>{studio_name}</p>' where key = 'retention_unconverted';
update notification_templates set text_body = 'Hi {first_name},

I noticed it has been {days_since} days since your last class, and I wanted to check in — no pressure at all. You were coming so regularly and we have missed you on the {last_class} mat.

If something got in the way, tell me and we will sort it. Otherwise, your next class is ready when you are.

[Book a class]({book_url}){button}

Warmly,
{studio_name}', html_body = '<p>Hi {first_name},</p>
<p>I noticed it has been {days_since} days since your last class, and I wanted to check in — no pressure at all. You were coming so regularly and we have missed you on the {last_class} mat.</p>
<p>If something got in the way, tell me and we will sort it. Otherwise, your next class is ready when you are.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Book a class</a></td></tr></table>
<p>Warmly,<br>{studio_name}</p>' where key = 'retention_at_risk';
update notification_templates set text_body = 'Hi {first_name},

Just a soft note — we have not seen you in a little while and wanted you to know the mat is always here. No rush, no pressure.

Whenever you fancy it, here is the timetable.

[See the timetable]({book_url}){button}

{studio_name}', html_body = '<p>Hi {first_name},</p>
<p>Just a soft note — we have not seen you in a little while and wanted you to know the mat is always here. No rush, no pressure.</p>
<p>Whenever you fancy it, here is the timetable.</p>
<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{book_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">See the timetable</a></td></tr></table>
<p>{studio_name}</p>' where key = 'retention_drifting';
update notification_templates set text_body = 'Hi {first_name},

A quick heads-up: your {plan_name} ends on {expires_on}. If you would like to keep your spot and your rhythm going, you can renew here.

::: card
name: {plan_name}
detail: Ends {expires_on}
button: Renew | {buy_url}
:::

See you on the mat,
{studio_name}', html_body = '<p>Hi {first_name},</p>
<p>A quick heads-up: your {plan_name} ends on {expires_on}. If you would like to keep your spot and your rhythm going, you can renew here.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:14px;line-height:20px;color:#57534E;margin-top:4px">Ends {expires_on}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">Renew</a></td></tr></table></div></td></tr></table>
<p>See you on the mat,<br>{studio_name}</p>' where key = 'retention_expiring';
update notification_templates set text_body = 'Hi {first_name},

It has been a little while since your {plan_name} wrapped up, and we would genuinely love to have you back.

If you are ready, here is a fresh start.

::: card
name: {plan_name}
button: A fresh start | {buy_url}
:::

And if there is anything we could do better, just reply — I read every one.

{studio_name}', html_body = '<p>Hi {first_name},</p>
<p>It has been a little while since your {plan_name} wrapped up, and we would genuinely love to have you back.</p>
<p>If you are ready, here is a fresh start.</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td style="border:1px solid #E7E5E4;border-radius:8px;padding:16px"><div style="font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:16px;font-weight:600;color:#14170E">{plan_name}</div><div style="margin-top:4px"><table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:16px 0"><tr><td align="center" style="border-radius:6px;background:{accent}"><a href="{buy_url}" style="display:inline-block;padding:11px 24px;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Helvetica,Arial,sans-serif;font-size:15px;font-weight:600;line-height:1;color:{accent_on};text-decoration:none;border-radius:6px">A fresh start</a></td></tr></table></div></td></tr></table>
<p>And if there is anything we could do better, just reply — I read every one.</p>
<p>{studio_name}</p>' where key = 'retention_lapsed';
