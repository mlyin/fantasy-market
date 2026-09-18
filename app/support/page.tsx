import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Support · Fantasy Market',
  description: 'Help with Fantasy Market, the play-money game for private fantasy leagues.',
};

const ISSUES_URL = 'https://github.com/mlyin/fantasy-market/issues';

export default function SupportPage() {
  return (
    <main>
      <section className="panel">
        <h1>Support</h1>
        <p>
          Fantasy Market is a play-money prediction game for a private fantasy league,
          played inside iMessage.
        </p>

        <h2>Get help</h2>
        <p>
          Open an issue at <a href={ISSUES_URL}>github.com/mlyin/fantasy-market/issues</a>.
          If the problem is about a specific market, include your league’s invite code.
        </p>

        <h2>Common questions</h2>
        <ul>
          <li>
            <strong>Is any real money involved?</strong> No. Every league starts with
            $10,000 of play money. Nothing can be deposited, withdrawn or won.
          </li>
          <li>
            <strong>How do friends join?</strong> Share the invite code or the Messages
            card. Tapping the card joins the league.
          </li>
          <li>
            <strong>How do I delete my data?</strong> Ask on the issues page with your
            invite code and we will remove the league and everything in it.
          </li>
          <li>
            <strong>Where is the privacy policy?</strong>{' '}
            <a href="/privacy">fantasy-market-nine.vercel.app/privacy</a>
          </li>
        </ul>
      </section>
    </main>
  );
}
