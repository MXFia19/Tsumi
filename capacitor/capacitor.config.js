// The live-reload dev server is only used when explicitly asked for (NODE_ENV=development,
// see the dev:* scripts). Defaulting to it made release builds load http://localhost:5001
// instead of the bundled app, which shows a black screen on the phone.
const mode = process.env.NODE_ENV?.trim() || 'production'

const config = {
  appId: 'org.tsumi.app',
  appName: 'Tsumi',
  webDir: 'build',
  android: {
    buildOptions: {
      keystorePath: './tsumi',
      keystorePassword: '',
      keystoreAlias: 'tsumi'
    },
    webContentsDebuggingEnabled: true
  },
  plugins: {
    SplashScreen: { launchShowDuration: 0 },
    CapacitorHttp: { enabled: true },
    LocalNotifications: { sound: 'ic_notification.wav' }
  },
  server: {
    cleartext: true
  }
}

if (mode === 'development') config.server.url = 'http://localhost:5001/index.html'

module.exports = config
