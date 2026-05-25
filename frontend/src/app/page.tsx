import Image from "next/image";
import {
  ArrowRight,
  Check,
  Clock3,
  CloudOff,
  Command,
  Download,
  Film,
  MousePointerClick,
  Play,
  Scissors,
  Sparkles,
  Wand2,
  type LucideIcon,
} from "lucide-react";

const featureBlocks: Array<{
  icon: LucideIcon;
  title: string;
  text: string;
}> = [
  {
    icon: MousePointerClick,
    title: "Automatic zoom",
    text: "FocusFrame follows clicks and cursor intent so viewers always know where to look.",
  },
  {
    icon: Scissors,
    title: "Timeline editing",
    text: "Trim, cut, tune zoom segments, add captions, chapters, title cards, and overlays.",
  },
  {
    icon: Wand2,
    title: "Style controls",
    text: "Backgrounds, padding, rounded corners, shadows, cursor scale, and webcam layouts.",
  },
  {
    icon: CloudOff,
    title: "Local-first export",
    text: "Recording, editing, transcription, and export run on your Mac by default.",
  },
];

const downloadHref = "/FocusFrame-1.0-macOS.zip";

const heroSignals = ["Free forever", "No login", "Local export"];

const controlRows: Array<{
  icon: LucideIcon;
  title: string;
  detail: string;
  value: string;
}> = [
  {
    icon: Command,
    title: "Recorder controls",
    detail: "Floating toolbar, countdown, mic, webcam, and cursor capture.",
    value: "Native",
  },
  {
    icon: Sparkles,
    title: "Zoom path",
    detail: "Automatic focus points with smooth pan and click emphasis.",
    value: "Auto",
  },
  {
    icon: Wand2,
    title: "Scene style",
    detail: "Backgrounds, padding, rounded corners, shadows, and badges.",
    value: "Polish",
  },
  {
    icon: Film,
    title: "Export presets",
    detail: "Landscape, vertical, square, GIF, MP4, MOV, and share pages.",
    value: "4K",
  },
];

const faqs = [
  {
    q: "Is FocusFrame really free?",
    a: "Yes. No payment, subscription, license key, or account login is required. Screen recording should be accessible.",
  },
  {
    q: "Do I need to log in after installing?",
    a: "No. FocusFrame runs locally on your Mac. Download it, install it, grant macOS permissions, and start recording.",
  },
  {
    q: "Is FocusFrame built for macOS?",
    a: "Yes. FocusFrame is a native macOS screen recorder built with SwiftUI, ScreenCaptureKit, AVFoundation, and AppKit where needed.",
  },
  {
    q: "Does it upload recordings automatically?",
    a: "No. The app is local-first. Optional cloud upload can be connected later through your own upload endpoint.",
  },
  {
    q: "What makes it different from normal screen recording?",
    a: "The editor is built for demos: auto zooms, cursor polish, timeline edits, captions, webcam layouts, style presets, and export profiles.",
  },
  {
    q: "Can I export for social and product launches?",
    a: "Yes. FocusFrame supports clean exports for product demos, tutorials, course clips, social posts, and share pages.",
  },
];

function BrandMark() {
  return (
    <span className="brand-icon" aria-hidden="true">
      <Image
        src="/focusframe-app-icon.png"
        alt=""
        width={28}
        height={28}
      />
    </span>
  );
}

function DemoVisual() {
  return (
    <section className="demo-visual video-showcase" aria-label="FocusFrame workflow video">
      <div className="video-copy">
        <span>Product loop</span>
        <h2>See how the recording turns into a guided demo.</h2>
        <p>
          The demo stays lightweight on the website while showing the actual
          flow: capture the screen, highlight the cursor, add the zoom, then
          export a clean file.
        </p>
      </div>
      <div className="video-frame">
        <div className="video-topbar">
          <span />
          <span />
          <span />
          <strong>FocusFrame workflow</strong>
        </div>
        <video
          aria-label="FocusFrame product workflow animation"
          autoPlay
          loop
          muted
          playsInline
          poster="/focusframe-demo-poster.png"
          preload="metadata"
        >
          <source src="/focusframe-demo.mp4" type="video/mp4" />
        </video>
        <div className="video-steps" aria-hidden="true">
          <span>Record</span>
          <span>Auto zoom</span>
          <span>Export</span>
        </div>
      </div>
    </section>
  );
}

function SectionTitle({
  label,
  title,
  text,
}: {
  label?: string;
  title: string;
  text?: string;
}) {
  return (
    <div className="section-title">
      {label ? <p>{label}</p> : null}
      <h2>{title}</h2>
      {text ? <span>{text}</span> : null}
    </div>
  );
}

export default function Home() {
  return (
    <main className="landing-page">
      <nav className="top-nav" aria-label="Primary navigation">
        <a href="#top" className="brand">
          <BrandMark />
          FocusFrame
        </a>
        <div className="nav-links">
          <a href="#features">Features</a>
          <a href="#download">Free</a>
          <a href="#faq">FAQ</a>
          <a href="#setup">Setup</a>
        </div>
        <a href={downloadHref} download className="nav-button">
          Download free
        </a>
      </nav>

      <section className="hero" id="top">
        <div className="hero-app-icon" aria-hidden="true">
          <Image
            src="/focusframe-app-icon.png"
            alt=""
            width={108}
            height={108}
            priority
          />
        </div>
        <a href="#features" className="intro-pill">
          FocusFrame - native demo recorder for macOS
        </a>
        <h1>
          Auto-zoom screen recorder
          <br />
          for macOS.
        </h1>
        <p>
          Record once, then let FocusFrame turn clicks, cursor movement,
          captions, and webcam into a clean guided video that feels edited by a
          demo producer.
        </p>
        <div className="hero-actions">
          <a href={downloadHref} download className="download-button primary">
            <span className="apple-mark" aria-hidden="true" />
            Download free
          </a>
          <a href="#preview" className="download-button secondary">
            <Play aria-hidden size={18} />
            See the frame system
          </a>
        </div>
        <div className="hero-signals" aria-label="Product promises">
          {heroSignals.map((signal) => (
            <span key={signal}>{signal}</span>
          ))}
        </div>
      </section>

      <DemoVisual />

      <section className="feature-intro" id="features">
        <SectionTitle
          title="Guided editing, not a heavy editor."
          text="FocusFrame keeps the important controls close: zooms, cursor polish, captions, styling, and export. It feels more like directing the viewer than editing from scratch."
        />
        <div className="editor-showcase" id="preview" aria-label="FocusFrame editor interface preview">
          <div className="editor-titlebar">
            <div className="window-lights" aria-hidden="true">
              <span />
              <span />
              <span />
            </div>
            <strong>FocusFrame</strong>
            <button type="button">Close Editor</button>
          </div>
          <div className="editor-toolbar">
            <div className="recording-meta">
              <strong>New Recording</strong>
              <span>0:00 / 4:06</span>
            </div>
            <nav aria-label="Editor tools">
              <span>Tool</span>
              <b>Timeline</b>
              <span>Cut</span>
              <span>Effects</span>
              <span>Speed</span>
              <span>Zoom</span>
            </nav>
            <a href={downloadHref} download>
              <Download aria-hidden size={16} />
              Export
            </a>
          </div>
          <div className="editor-body">
            <div className="editor-main">
              <div className="editor-stage">
                <div className="recording-stage">
                  <div className="terminal-frame">
                    <span />
                    <span />
                    <span />
                    <i />
                  </div>
                  <button className="cursor-focus-control" type="button" aria-label="Preview cursor focus point">
                    <MousePointerClick aria-hidden size={16} />
                    <span>Focus point</span>
                  </button>
                  <div className="camera-preview" aria-hidden="true" />
                </div>
              </div>
              <div className="playback-row">
                <button type="button" aria-label="Play preview">
                  <Play aria-hidden size={18} />
                </button>
                <span />
                <em>0:00</em>
              </div>
              <div className="timeline-ruler">
                {["0:00", "0:15", "0:30", "0:45", "1:00", "1:15", "1:30", "1:45", "2:00", "2:15", "2:30", "2:45", "3:00"].map(
                  (tick) => (
                    <span key={tick}>{tick}</span>
                  ),
                )}
              </div>
              <div className="editor-tracks">
                <div className="track-row video-track">
                  <strong>Layouts</strong>
                  <div className="clips">
                    <i />
                    <i />
                    <i />
                    <i />
                  </div>
                </div>
                <div className="track-row audio-track">
                  <strong>Mic</strong>
                  <div className="waveform" />
                </div>
              </div>
            </div>
            <aside className="editor-inspector">
              <div className="inspector-head">
                <strong>Customize</strong>
                <span>Local project settings</span>
              </div>
              <div className="segmented-tabs">
                <b>Smart</b>
                <span>Advanced</span>
              </div>
              <div className="smart-card">
                <Sparkles aria-hidden size={20} />
                <strong>Smart Finish</strong>
                <p>Applies the best local defaults for look, focus, captions, camera, and branding.</p>
                <button type="button">
                  <Wand2 aria-hidden size={16} />
                  Apply Smart Finish
                </button>
              </div>
              <div className="quick-looks">
                {["Studio", "Product", "Creator", "Course", "Minimal", "Social"].map((look) => (
                  <div key={look}>
                    <Sparkles aria-hidden size={16} />
                    <strong>{look}</strong>
                    <span>Polished local preset</span>
                  </div>
                ))}
              </div>
            </aside>
          </div>
        </div>
      </section>

      <section className="more-section">
        <SectionTitle title="A focused set of polish controls." />
        <div className="more-grid">
          <div className="control-list">
            {controlRows.map((row) => {
              const Icon = row.icon;
              return (
                <article className="control-item" key={row.title}>
                  <Icon aria-hidden size={17} />
                  <div>
                    <strong>{row.title}</strong>
                    <span>{row.detail}</span>
                  </div>
                  <em>{row.value}</em>
                </article>
              );
            })}
          </div>
          <div className="toolbar-preview">
            <div className="soft-wallpaper">
              <div className="canvas-card">
                <div className="canvas-top">
                  <span>16:9</span>
                  <span>Auto zoom</span>
                </div>
                <div className="canvas-focus">
                  <MousePointerClick aria-hidden size={22} />
                </div>
                <div className="caption-strip">Cursor path captured</div>
              </div>
              <div className="floating-toolbar" aria-hidden="true">
                <span />
                <span />
                <span />
                <span />
                <span />
                <span />
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="feature-cards">
        {featureBlocks.map((item) => {
          const Icon = item.icon;
          return (
            <article key={item.title}>
              <Icon aria-hidden size={22} />
              <h3>{item.title}</h3>
              <p>{item.text}</p>
            </article>
          );
        })}
      </section>

      <section className="pricing-section" id="download">
        <div className="offer-pill">Free forever</div>
        <SectionTitle
          title="Recording tools should be free."
          text="No checkout, no subscription, no lifetime pass, and no license-key login after install."
        />
        <div className="pricing-grid free-grid">
          <article className="price-card featured free-card">
            <div className="price-head">
              <span>Lifetime access</span>
              <i>No payment</i>
            </div>
            <div className="price-line free-line">
              <span className="old-price">Rs 1,000</span>
              <strong>Free</strong>
              <em>forever</em>
            </div>
            <p>
              FocusFrame is free for macOS screen recording, editing, captions,
              cursor polish, and local exports.
            </p>
            <ul>
              <li>
                <Check aria-hidden size={16} />
                No checkout or payment page
              </li>
              <li>
                <Check aria-hidden size={16} />
                No account or license verification
              </li>
              <li>
                <Check aria-hidden size={16} />
                Local-first recording and export
              </li>
              <li>
                <Check aria-hidden size={16} />
                Built for creators who just want to record
              </li>
            </ul>
            <a href={downloadHref} download className="buy-button">
              Download free
              <ArrowRight aria-hidden size={17} />
            </a>
          </article>
          <article className="price-card promise-card">
            <div className="price-head">
              <span>Creator promise</span>
            </div>
            <p>
              Screen recordings are meant to be free. FocusFrame stays simple:
              download the Mac app, install it, and record without a purchase
              flow getting in the way.
            </p>
            <ul>
              <li>
                <Check aria-hidden size={16} />
                No Rs 100/month plan
              </li>
              <li>
                <Check aria-hidden size={16} />
                No hidden lifetime upgrade
              </li>
              <li>
                <Check aria-hidden size={16} />
                No email gate after install
              </li>
            </ul>
          </article>
        </div>
      </section>

      <section className="setup-section" id="setup">
        <SectionTitle
          label="Fast setup"
          title="Record, guide, ship."
          text="Install the app, allow macOS screen recording permissions, capture a short walkthrough, then tune the zooms and export."
        />
        <div className="setup-steps">
          <div>
            <Clock3 aria-hidden size={20} />
            <strong>Record</strong>
            <span>Screen, window, mic, system audio, webcam, cursor.</span>
          </div>
          <div>
            <Sparkles aria-hidden size={20} />
            <strong>Polish</strong>
            <span>Auto zooms, captions, styles, backgrounds, badges.</span>
          </div>
          <div>
            <Download aria-hidden size={20} />
            <strong>Export</strong>
            <span>MP4, MOV, GIF, local share page, or clipboard file.</span>
          </div>
        </div>
      </section>

      <section className="faq-section" id="faq">
        <SectionTitle
          title="Help Center"
          text="Browse the key questions before downloading FocusFrame."
        />
        <div className="faq-list">
          {faqs.map((faq) => (
            <details key={faq.q}>
              <summary>
                {faq.q}
                <span>+</span>
              </summary>
              <p>{faq.a}</p>
            </details>
          ))}
        </div>
      </section>

      <section className="final-cta">
        <h2>Make your next demo feel intentional.</h2>
        <div>
          <a href={downloadHref} download className="buy-button">
            Download free
            <ArrowRight aria-hidden size={17} />
          </a>
          <a href="#features" className="ghost-buy light">
            See features
            <ArrowRight aria-hidden size={17} />
          </a>
        </div>
      </section>

      <footer>
        <div>
          <a href="#top" className="brand footer-brand">
            <BrandMark />
            FocusFrame
          </a>
          <p>
            Create sleek, professional screen recordings with auto zoom,
            timeline editing, cursor polish, captions, and local-first exports.
          </p>
        </div>
        <nav aria-label="Footer navigation">
          <a href="#features">Features</a>
          <a href="#download">Free</a>
          <a href="#faq">FAQ</a>
        </nav>
      </footer>
    </main>
  );
}
