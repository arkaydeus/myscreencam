"use client";

import { useState } from "react";

export function CopyLicence({ licence }: { licence: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="mt-8 rounded-2xl bg-white p-5 text-left">
      <code className="block text-sm break-all select-all">{licence}</code>
      <button
        type="button"
        className="mt-4 rounded-full bg-primary px-5 py-2 text-primary-foreground"
        onClick={async () => {
          await navigator.clipboard.writeText(licence);
          setCopied(true);
        }}
      >
        {copied ? "Copied" : "Copy licence key"}
      </button>
    </div>
  );
}
