import Link from "next/link";
export default function SettingsBack() {
  return (
    <Link href="/settings" className="mb-4 inline-block text-[13px] text-ink-2 underline underline-offset-4">
      ← All settings
    </Link>
  );
}
