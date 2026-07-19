import type { Metadata } from "next";
import { SiteFooter, SiteHeader } from "../site-chrome";

export const metadata: Metadata = {
  title: "Terms of Service · Edith",
  description: "Terms of service for Edith, the macOS menu bar app.",
  alternates: {
    canonical: "/terms",
  },
};

export default function TermsPage() {
  return (
    <>
      <SiteHeader />
      <main className="mx-auto max-w-190 px-6 pt-35 pb-24 [&>h1]:mb-2! [&>h1]:text-[clamp(2rem,5vw,2.8rem)]! [&>h1]:tracking-[-0.02em]! [&>h2]:mt-10! [&>h2]:mb-3! [&>h2]:text-[20px]! [&>p]:mb-3 [&>p]:text-muted [&>p]:leading-[1.7] [&>ul]:mb-4 [&>ul]:list-disc [&>ul]:pl-5.5 [&_a]:text-accent [&_li]:mb-3 [&_li]:text-muted [&_li]:leading-[1.7]">
        <h1>Terms of Service</h1>
        <p className="mb-10! text-[0.9rem]! text-subtle!">Last updated: July 19, 2026</p>

        <p>
          These terms govern your purchase and use of the Edith macOS
          application (&quot;the app&quot;) and the edith.app website. By buying
          or using the app you agree to them.
        </p>

        <h2>License</h2>
        <p>
          Your one-time purchase grants you a personal, non-exclusive,
          non-transferable, perpetual license to install and use the purchased
          version of the app on Macs that you own or control. This is a
          license, not a sale of the software itself.
        </p>
        <ul>
          <li>
            A license may be active on the number of Macs included with the
            purchased plan. The applicable allowance is shown at checkout and
            in the order confirmation.
          </li>
          <li>
            Active Macs may be replaced through the device-management service,
            subject to reasonable safeguards against abuse.
          </li>
          <li>
            Team or company use requires the applicable user or team licenses
            unless the order states otherwise.
          </li>
          <li>
            You may not resell, sublicense, or redistribute the app or your
            license key.
          </li>
        </ul>

        <h2>License verification</h2>
        <p>
          You own a perpetual license to the version you purchased. To prevent
          abuse of the per-plan device allowance, the app periodically refreshes
          a signed entitlement from our licensing service, and continues to work
          offline for at least 30 days after the last successful refresh. If the
          entitlement cannot be refreshed after that grace period, the app
          enters a recovery mode in which your local data, settings, and export
          remain fully accessible while feature engines pause until the license
          is verified again.
        </p>
        <p>
          If we ever discontinue the licensing service, we commit to releasing a
          final build or update that removes the online verification requirement
          so paid licenses keep working.
        </p>

        <h2>Updates</h2>
        <p>
          Your license includes app updates for as long as they ship. Updates
          may add, change, or remove features. We are not obligated to maintain
          any particular feature indefinitely, including features that depend on
          third-party APIs.
        </p>

        <h2>Third-party services</h2>
        <p>
          Some features read data from, or send requests to, services you
          already use, such as your AI provider&apos;s rate-limit API, iCloud,
          or media sources. Those services belong to their providers, are
          governed by their terms, and can change or break without notice. The
          app&apos;s integrations are provided as-is.
        </p>

        <h2>Refunds</h2>
        <p>
          If the app doesn&apos;t work for you, email us within 14 days of
          purchase and we&apos;ll refund your order.
        </p>

        <h2>Acceptable use</h2>
        <p>
          Don&apos;t use the app to violate any law, and don&apos;t attempt to
          circumvent license checks or redistribute builds. You may inspect and
          build the source where it is publicly available; distributing paid
          builds to others is not permitted.
        </p>

        <h2>Disclaimer and liability</h2>
        <p>
          The app is provided &quot;as is&quot;, without warranty of any kind.
          To the maximum extent permitted by law, we are not liable for any
          indirect, incidental, or consequential damages arising from your use
          of the app. Our total liability for any claim is limited to the amount
          you paid for your license.
        </p>

        <h2>Changes to these terms</h2>
        <p>
          We may update these terms from time to time. The current version
          always lives at this page, with the date above. Continued use of the
          app after a change means you accept the updated terms.
        </p>

        <h2>Contact</h2>
        <p>
          Questions? Email{" "}
          <a href="mailto:support@edith.app">support@edith.app</a>.
        </p>
      </main>
      <SiteFooter />
    </>
  );
}
