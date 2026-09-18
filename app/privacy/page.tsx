import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Privacy Policy · Fantasy Market',
  description: 'What Fantasy Market collects, where it lives, and how to delete it.',
};

export default function PrivacyPage() {
  return (
    <main>
      <section className="panel">
        <h1>Privacy Policy</h1>
        <p className="muted">Effective September 18, 2026</p>
        <p>
          Fantasy Market is a play-money game for private fantasy leagues. It runs as an
          iMessage extension and as this companion website. There is no real money: no
          deposits, no withdrawals, no prizes and no payouts.
        </p>

        <h2>What we collect</h2>
        <ul>
          <li>
            <strong>An anonymous account.</strong> Tapping “Enter market” creates an
            account identified by a random ID. We do not ask for your name, email
            address or phone number.
          </li>
          <li>
            <strong>What you type into the game:</strong> league names, the team or owner
            names you enter, and invite codes.
          </li>
          <li>
            <strong>What you do in the game:</strong> the orders you place, the trades
            that result, and your play-money balance.
          </li>
          <li>
            <strong>Basic technical logs</strong> kept by our hosting provider, such as IP
            address and request time, used only to run and secure the service.
          </li>
        </ul>

        <h2>What we do not collect</h2>
        <p>
          No location, contacts, photos, advertising identifiers or analytics. The app
          contains no ads and no third-party tracking.
        </p>

        <h2>Messages</h2>
        <p>
          Cards you share in Messages carry the league name, the invite code and current
          prices. Apple delivers them; we never see your conversations.
        </p>

        <h2>Where data lives and who sees it</h2>
        <p>
          Data is stored with Supabase, our database and sign-in provider, on servers in
          the United States. Members of your league can see that league’s markets, orders
          and trades, which is the point of the game. We do not sell data and do not share
          it with anyone else, except where the law requires it.
        </p>

        <h2>Deleting your data</h2>
        <p>
          Ask on the <a href="/support">support page</a> with your league’s invite code
          and we will delete the league and everything in it.
        </p>

        <h2>Children</h2>
        <p>Fantasy Market is not directed at children under 13.</p>

        <h2>Changes</h2>
        <p>Any change to this policy will be posted here with a new effective date.</p>

        <h2>Contact</h2>
        <p>
          Questions go through the <a href="/support">support page</a>.
        </p>
      </section>
    </main>
  );
}
