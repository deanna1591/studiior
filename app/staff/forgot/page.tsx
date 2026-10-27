import ForgotForm from "./form";

export const dynamic = "force-dynamic";

/** Decision 84 — staff forgot password. Studiior-generic (no studio slug on
 *  the staff host, and a staff user may belong to several studios). */
export default function StaffForgot() {
  return (
    <div className="mx-auto max-w-sm px-5 py-16">
      <h1 className="text-xl font-semibold tracking-tight">Reset your password</h1>
      <p className="mb-6 mt-1 text-sm text-ink-3">
        Enter your email and we&rsquo;ll send a link to set a new password.
      </p>
      <ForgotForm />
    </div>
  );
}
