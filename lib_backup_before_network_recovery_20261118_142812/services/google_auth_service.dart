import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class GoogleAuthService {
  GoogleAuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;
  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  static Future<void>? _initialization;

  Future<void> _initializeGoogleSignIn() {
    const serverClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
    return _initialization ??= _googleSignIn.initialize(
      serverClientId: serverClientId.isEmpty ? null : serverClientId,
    );
  }

  Stream<User?> get authStateChanges => _auth.authStateChanges();
  User? get currentUser => _auth.currentUser;

  Future<UserCredential> signInWithGoogle() async {
    await _initializeGoogleSignIn();
    if (!_googleSignIn.supportsAuthenticate()) {
      throw UnsupportedError(
        'This sign-in flow currently supports Android and iOS app builds.',
      );
    }
    final account = await _googleSignIn.authenticate();
    final googleAuth = account.authentication;
    final idToken = googleAuth.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw StateError(
        'Google did not return an ID token. Check the Android SHA fingerprints '
        'and Google OAuth configuration in Firebase.',
      );
    }
    final credential = GoogleAuthProvider.credential(idToken: idToken);
    return _auth.signInWithCredential(credential);
  }

  Future<void> signOut() async {
    await _auth.signOut();
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Firebase sign-out is authoritative; Google sign-out is best-effort.
    }
  }
}
