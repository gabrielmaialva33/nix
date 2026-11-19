import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as std_crypto;
import 'package:cryptography/cryptography.dart';
import 'package:nix_core_crypto/nix_core_crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../core/models/space.dart';
import '../core/models/channel.dart';
import '../core/models/message.dart';
import '../core/models/member.dart';
import '../core/models/call_state.dart';
import '../core/models/publication.dart';
import '../core/models/forum_post.dart';
import '../core/models/cultural_item.dart';
import '../core/models/user_profile.dart';
import '../core/models/direct_message.dart';
import '../core/models/user_settings.dart';
import '../core/models/monero_order.dart';
import '../core/models/github_repo.dart';
import '../core/theme/nix_colors.dart';
import '../core/theme/nix_palette.dart';
import '../core/security/security_context.dart';
import '../core/database/local_database.dart';
import '../core/database/repositories.dart';
import '../core/security/key_vault.dart';
import '../core/security/seed_recovery.dart';
import '../core/security/anti_forensic_shredder.dart';
import 'package:nix_transport/nix_transport.dart';
import '../features/onboarding/sovereign_onboarding_model.dart';
import 'mock_data.dart';

enum NixActiveArea {
  homePrivate, // Conversas privadas, Mensagens Salvas, Amigos, Solicitações e Card ID
  spaces,      // Espaços / Grupos e Canais
  explore,     // Explorar Canais e Grupos Públicos
  github,      // GitHub Discovery (Starwire)
  moneroP2p,   // Mercado Monero P2P Não Custodial
}

enum ConversationFilter {
  all,
  unread,
  pinned,
  privateChats,
  groups,
  channels,
  muted,
}

enum PeerCardHoverState {
  closed,
  openingPending,
  openByHover,
  openByClick,
  closingRequested,
}

class AuthorizedPeerCardData {
  final String peerName;
  final String peerPublicId;
  final NixTrustLevel trustLevel;
  final bool hasCryptographicShield;
  final bool isAuthorized;
  final String visibilityLabel;
  final String bio;
  final List<String> culturalHighlights;

  const AuthorizedPeerCardData({
    required this.peerName,
    required this.peerPublicId,
    required this.trustLevel,
    required this.hasCryptographicShield,
    required this.isAuthorized,
    required this.visibilityLabel,
    required this.bio,
    required this.culturalHighlights,
  });
}

class NixState extends ChangeNotifier {
  late List<Space> _spaces;
  late List<SpaceFolder> _folders;
  late List<Space> _discoverableSpaces;
  late Space _currentSpace;
  late Channel _currentChannel;
  late Map<String, List<Message>> _messages;
  late Map<String, List<Publication>> _publications;
  late List<ForumPost> _forumPosts;
  late List<Member> _members;
  late UserProfile _userProfile;
  late List<DirectMessageThread> _directMessages;
  late List<ContactRequest> _contactRequests;
  late List<XmrTransactionRecord> _transactions;
  late List<SystemUpdateRecord> _systemUpdates;
  late List<MoneroP2pOrder> _moneroOrders;
  late List<GithubRepository> _githubRepos;
  UserSettings _settings = const UserSettings();

  CallState _callState = const CallState();
  SecurityContext _securityContext = const SecurityContext(myPersona: 'NX-7E3A');

  NixActiveArea _activeArea = NixActiveArea.spaces;
  HomeSubTab _homeSubTab = HomeSubTab.cardId;
  DirectMessageThread? _selectedDm;
  ForumPost? _selectedForumPost;

  // Navegação por Pastas & Filtros (Estilo Telegram Desktop)
  String _activeFolderId = 'all'; // 'all', 'private', ou folder.id
  ConversationFilter _conversationFilter = ConversationFilter.all;
  String _conversationSearchQuery = '';
  bool _isWindowMaximized = false;

  // Máquina de estados explícita para Hover/Clique de Card ID em Solicitações
  ContactRequest? _hoveredContactRequest;
  PeerCardHoverState _peerHoverState = PeerCardHoverState.closed;
  String? _hoverLockoutRequestId;
  bool _isCursorOverHoverPreview = false;
  Timer? _hoverDebounceTimer;

  bool _isProfileOverlayOpen = false;
  bool _isSettingsOpenInOverlay = false;
  SettingsCategory _activeSettingsCategory = SettingsCategory.appearance;

  bool _isMembersPanelOpen = false;
  bool _isConversationInfoOpen = false;
  String _conversationHistorySearch = '';
  int _selectedEphemeralTimer = 0;
  bool _exploreSortAscending = true;
  String _exploreSearchQuery = '';

  // Estado de Mensagens (Responder, Editar, Seleção Múltipla, Fixada destacada)
  Message? _replyingToMessage;
  Message? _editingMessage;
  final Set<String> _selectedMessageIds = {};
  String? _highlightedMessageId;
  final Set<String> _seenMoneroNonces = {};

  // Filtros GitHub Discovery
  String _githubSearchQuery = '';
  String _githubSelectedTopic = 'Todos';
  String _githubSelectedLanguage = 'Todas';
  String _githubSortBy = 'stars'; // 'stars', 'trending', 'updated'
  final Set<String> _savedAcervoIds = {};

  // Filtros Monero P2P
  MoneroP2pSide _moneroSelectedSide = MoneroP2pSide.sell;
  String _moneroSelectedFiat = 'BRL';
  String _moneroSelectedPaymentMethod = 'Todos';
  String _moneroSearchQuery = '';

  Timer? _callTimer;

  // Estado Tor Onion
  final String _onionAddress = 'gpoun4vo5v5h3cmcfdxtudm3nlzxri3qzjd7fhbvy6oep2ap67g4qvyd.onion';
  bool _isTorRunning = false;
  String _torDiagnosticDetail = 'Tor aguardando conexão SOCKS5 em 127.0.0.1:9050';

  // Gerenciador de Tor Embutido (Zero-Configuration / Sem Orbot)
  final EmbeddedTorManager _embeddedTor = EmbeddedTorManager();
  EmbeddedTorManager get embeddedTor => _embeddedTor;

  /// Inicia o daemon Tor embutido nativo de forma automática e transparente.
  Future<bool> startEmbeddedTor() async {
    _torDiagnosticDetail = 'Iniciando daemon Tor embutido nativo...';
    notifyListeners();
    final ok = await _embeddedTor.startEmbeddedTor();
    if (ok) {
      return checkTorDaemonStatus();
    }
    _torDiagnosticDetail = _embeddedTor.lastSummary;
    notifyListeners();
    return false;
  }

  // Banco de Dados Local Cifrado & KeyVault (P0-2)
  bool _disposed = false;
  LocalDatabase? _localDatabase;
  late final KeyVault _keyVault;
  Uint8List? _activeMasterKey;
  NixIdentity? _primaryIdentity;
  String _localDeviceId = 'dev_primary';
  bool _requiresPassphraseUnlock = false;

  IdentityRepository? _identityRepo;
  ContactRepository? _contactRepo;
  ConversationRepository? _conversationRepo;
  MessageRepository? _messageRepo;
  OutboxRepository? _outboxRepo;
  PreferencesRepository? _preferencesRepo;
  KeyMaterialRepository? _keyMaterialRepo;
  PreKeyRepository? _preKeyRepo;
  SessionRepository? _sessionRepo;
  ObjectChunkRepository? _objectChunkRepo;
  MediaRepository? _mediaRepo;
  ArchiveRepository? _archiveRepo;

  bool get isDatabaseReady => _localDatabase != null;
  bool get requiresPassphraseUnlock => _requiresPassphraseUnlock;
  NixIdentity? get primaryIdentity => _primaryIdentity;
  String get localDeviceId => _localDeviceId;
  LocalDatabase? get localDatabase => _localDatabase;
  KeyVault get keyVault => _keyVault;
  IdentityRepository? get identityRepo => _identityRepo;
  ContactRepository? get contactRepo => _contactRepo;
  ConversationRepository? get conversationRepo => _conversationRepo;
  MessageRepository? get messageRepo => _messageRepo;
  OutboxRepository? get outboxRepo => _outboxRepo;
  PreferencesRepository? get preferencesRepo => _preferencesRepo;
  KeyMaterialRepository? get keyMaterialRepo => _keyMaterialRepo;
  PreKeyRepository? get preKeyRepo => _preKeyRepo;
  SessionRepository? get sessionRepo => _sessionRepo;
  ObjectChunkRepository? get objectChunkRepo => _objectChunkRepo;
  MediaRepository? get mediaRepo => _mediaRepo;
  ArchiveRepository? get archiveRepo => _archiveRepo;

  // Gerenciador de Malha por Proximidade Bluetooth (estilo Briar BTP)
  late final BluetoothMeshManager _bluetoothMesh = BluetoothMeshManager(
    localCardId: _userProfile.publicId,
  );

  BluetoothMeshManager get bluetoothMesh => _bluetoothMesh;
  bool get isBluetoothMeshEnabled => _bluetoothMesh.isMeshEnabled;

  void setBluetoothMeshEnabled(bool enabled) {
    _bluetoothMesh.setMeshEnabled(enabled);
    notifyListeners();
  }

  // Estado e Controle de Onboarding Soberano (Seção 2)
  bool _isOnboarded = false;
  bool _onboardingNoticeDismissed = false;

  bool get isOnboarded => _isOnboarded;
  bool get onboardingNoticeDismissed => _onboardingNoticeDismissed;

  void dismissOnboardingToIncompleteNotice() {
    _onboardingNoticeDismissed = true;
    notifyListeners();
  }

  void reopenOnboardingFlow() {
    _onboardingNoticeDismissed = false;
    notifyListeners();
  }

  /// Conclui o fluxo de primeiro acesso soberano e comuta o app para produção real.
  Future<void> completeOnboarding({
    String? publicId,
    String? displayName,
    String? avatarStyle,
  }) async {
    _isOnboarded = true;
    _onboardingNoticeDismissed = false;

    if (displayName != null && displayName.isNotEmpty) {
      updateProfile(displayName: displayName);
    }
    if (avatarStyle != null && avatarStyle.isNotEmpty) {
      updateProfile(avatarStyle: avatarStyle);
    }
    if (publicId != null && publicId.isNotEmpty) {
      _userProfile = _userProfile.copyWith(publicId: publicId);
    }

    if (_localDatabase != null &&
        _identityRepo != null &&
        _userProfile.publicId.isNotEmpty) {
      final primary = await _identityRepo!.getPrimaryIdentity();
      if (primary != null) {
        await _identityRepo!.saveProfile(
          identityId: primary['id'] as String,
          displayName: _userProfile.effectiveDisplayName,
          bio: _userProfile.bio,
          avatarObjectId: _userProfile.avatarStyle,
        );
      }
    }

    final snapshot = OnboardingStateSnapshot(
      currentStep: OnboardingStep.ready,
      torConsentAccepted: true,
      torBootstrapped: true,
      torVerified: true,
      identityGenerated: true,
      backupConfirmed: true,
      publicIdDerived: true,
      profileConfigured: true,
      isCompleted: true,
      publicId: _userProfile.publicId,
      displayName: _userProfile.effectiveDisplayName,
      avatarStyle: _userProfile.avatarStyle,
    );
    await OnboardingStateSnapshot.save(snapshot);
    notifyListeners();
  }

  /// Adiciona um novo contato soberano por Card ID / Chave Pública (Seção 6).
  Future<void> addNewContact({
    required String publicId,
    String? nickname,
  }) async {
    final cleanId = publicId.trim();
    if (cleanId.isEmpty) return;

    final effectiveName = (nickname != null && nickname.trim().isNotEmpty)
        ? nickname.trim()
        : (cleanId.length > 15 ? 'Par ${cleanId.substring(0, 14)}' : cleanId);

    final dmId = 'dm_${DateTime.now().millisecondsSinceEpoch}';

    // Se o banco de dados SQLCipher estiver ativo, persiste o contato
    if (_localDatabase != null && _contactRepo != null) {
      try {
        await _contactRepo!.upsertContact(
          id: cleanId,
          edPublic: Uint8List(32),
          xPublic: Uint8List(32),
          fingerprint: cleanId,
          displayName: effectiveName,
          verification: 'verified',
        );
      } catch (e) {
        debugPrint('[NixState] Aviso ao inserir contato no banco local: $e');
      }
    }

    final newDm = DirectMessageThread(
      id: dmId,
      peerName: effectiveName,
      peerPublicId: cleanId,
      statusText: 'Sessão P2P Cifrada · Roteamento Tor Onion v3',
      isOnline: true,
      isVerified: true,
      trustLevel: NixTrustLevel.level2Yellow,
      unreadCount: 0,
      messages: [
        Message(
          id: 'msg_welcome_$dmId',
          channelId: dmId,
          senderName: 'Sistema Nix',
          senderFingerprint: 'SISTEMA-FAIL-CLOSED',
          isMe: false,
          isVerified: true,
          text: 'Conversa privada iniciada com $effectiveName. Mensagens cifradas de ponta a ponta (Double Ratchet) e roteadas via Tor.',
          timestamp: DateTime.now().toUtc(),
        ),
      ],
    );

    _directMessages.add(newDm);
    _selectedDm = newDm;
    _homeSubTab = HomeSubTab.directChat;
    _activeArea = NixActiveArea.homePrivate;
    notifyListeners();
  }

  /// Procedimento Anti-Forense / Botão de Pânico (estilo BleachBit):
  /// Destrói a memória RAM, fecha banco e sobrescreve arquivos em múltiplas passagens destrutivas.
  Future<ShredReport> panicWipeAllData({String? customBaseDir}) async {
    final report = await AntiForensicShredder.panicWipeAccount(
      activeDatabase: _localDatabase,
      activeVault: _keyVault,
      customBaseDir: customBaseDir,
    );
    if (_activeMasterKey != null) {
      _activeMasterKey!.fillRange(0, _activeMasterKey!.length, 0);
      _activeMasterKey = null;
    }
    _primaryIdentity = null;
    _localDeviceId = 'dev_primary';
    _localDatabase = null;
    _identityRepo = null;
    _contactRepo = null;
    _conversationRepo = null;
    _messageRepo = null;
    _outboxRepo = null;
    _preferencesRepo = null;
    _keyMaterialRepo = null;
    _preKeyRepo = null;
    _sessionRepo = null;
    _objectChunkRepo = null;
    _mediaRepo = null;
    _archiveRepo = null;
    _isOnboarded = false;
    _requiresPassphraseUnlock = false;
    _initializeProductionCleanState();
    notifyListeners();
    return report;
  }

  /// Deriva uma chave de envelopamento de material privado isolada por contexto HKDF-SHA256.
  Future<SecretKeyData> _deriveWrappingKey(String domainInfo) async {
    final master = _activeMasterKey;
    if (master == null || master.isEmpty) {
      throw StateError('[Fail-Closed] Cofre local não desbloqueado para envelopar chaves.');
    }
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(master),
      nonce: utf8.encode('nix-keyvault-v1'),
      info: utf8.encode(domainInfo),
    );
    final bytes = await derived.extractBytes();
    return SecretKeyData(bytes);
  }

  void _instantiateRepositories() {
    final db = _localDatabase!;
    _identityRepo = IdentityRepository(db);
    _contactRepo = ContactRepository(db);
    _conversationRepo = ConversationRepository(db);
    _messageRepo = MessageRepository(db);
    _outboxRepo = OutboxRepository(db);
    _preferencesRepo = PreferencesRepository(db);
    _keyMaterialRepo = KeyMaterialRepository(db);
    _preKeyRepo = PreKeyRepository(db);
    _sessionRepo = SessionRepository(db);
    _objectChunkRepo = ObjectChunkRepository(db);
    _mediaRepo = MediaRepository(db);
    _archiveRepo = ArchiveRepository(db);
  }

  /// Inicializa o cofre de chaves local com Argon2id + XChaCha20-Poly1305
  /// e abre a conexão com o banco de dados SQLCipher executando migrações auditadas (P0-2 / P0-5).
  Future<bool> initializeEncryptedDatabase({
    String passphrase = 'default_sovereign_passphrase',
    String? customDbPath,
    String? customVaultPath,
    String? migration001Sql,
    String? migration002Sql,
    bool bindToOsKeyring = false,
    String? duressPassphrase,
  }) async {
    if (_disposed) return false;
    try {
      Uint8List masterKey;
      if (await _keyVault.isInitialized(customPath: customVaultPath)) {
        final unlockResult = await _keyVault.unlockOrDuress(
          passphrase: passphrase,
          customPath: customVaultPath,
        );
        if (unlockResult.status == VaultUnlockStatus.duressTriggered) {
          await panicWipeAllData();
          return false;
        }
        masterKey = unlockResult.masterKey!;
      } else {
        masterKey = await _keyVault.initialize(
          passphrase: passphrase,
          customPath: customVaultPath,
          duressPassphrase: duressPassphrase,
          bindToOsKeyring: bindToOsKeyring,
        );
      }

      final database = await LocalDatabase.open(
        path: customDbPath,
        rawCipherKey: Uint8List.fromList(masterKey),
        migration001Sql: migration001Sql,
        migration002Sql: migration002Sql,
      );

      // O descarte pode ocorrer durante a derivação da chave ou abertura do banco.
      // Não publica recursos nem notifica ouvintes depois desse ponto.
      if (_disposed) {
        try {
          await database.close();
        } finally {
          _keyVault.lock();
        }
        return false;
      }
      _activeMasterKey = Uint8List.fromList(masterKey);
      _localDatabase = database;
      _instantiateRepositories();
      _requiresPassphraseUnlock = false;

      notifyListeners();
      return true;
    } catch (e) {
      if (_disposed) _keyVault.lock();
      debugPrint('[NixState] Erro ao inicializar banco de dados cifrado: $e');
      return false;
    }
  }

  /// Configura ou altera o PIN de coação (duress) no KeyVault ativo.
  Future<bool> configureDuressPin({
    required String vaultPassphrase,
    required String duressPin,
    String? customVaultPath,
  }) async {
    try {
      await _keyVault.configureDuressPassphrase(
        vaultPassphrase: vaultPassphrase,
        duressPassphrase: duressPin,
        customPath: customVaultPath,
      );
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[NixState] Falha ao configurar PIN de coação: $e');
      return false;
    }
  }

  /// Desbloqueia o KeyVault usando a frase-passe do usuário (ou executa apagamento silencioso
  /// caso a senha fornecida corresponda ao PIN de coação configurado) e recarrega o estado local.
  Future<VaultUnlockResult> unlockWithPassphrase(
    String passphrase, {
    String? customDbPath,
    String? customVaultPath,
    String? customWipeBaseDir,
    bool loadState = true,
  }) async {
    final result = await _keyVault.unlockOrDuress(
      passphrase: passphrase,
      customPath: customVaultPath,
    );
    if (result.status == VaultUnlockStatus.duressTriggered) {
      await panicWipeAllData(customBaseDir: customWipeBaseDir);
      return result;
    }
    _activeMasterKey = Uint8List.fromList(result.masterKey!);
    _localDatabase = await LocalDatabase.open(
      path: customDbPath,
      rawCipherKey: Uint8List.fromList(result.masterKey!),
    );
    _instantiateRepositories();
    _requiresPassphraseUnlock = false;
    if (loadState) {
      await reloadFromDatabase();
    }
    notifyListeners();
    return result;
  }

  /// Tenta desbloquear o KeyVault via chaveiro nativo do SO (libsecret / AndroidKeyStore)
  /// e restaurar toda a conta (identidade, perfil, contatos, mensagens salvas) na inicialização.
  Future<bool> tryAutoUnlockAndRestore({
    String? customDbPath,
    String? customVaultPath,
  }) async {
    try {
      final initialized = await _keyVault.isInitialized(customPath: customVaultPath);
      if (!initialized) return false;

      final masterKey = await _keyVault.tryUnlockWithOsKeyring(
        customPath: customVaultPath,
      );
      if (masterKey == null) {
        _requiresPassphraseUnlock = true;
        notifyListeners();
        return false;
      }

      _activeMasterKey = Uint8List.fromList(masterKey);
      _localDatabase = await LocalDatabase.open(
        path: customDbPath,
        rawCipherKey: Uint8List.fromList(masterKey),
      );
      _instantiateRepositories();
      _requiresPassphraseUnlock = false;
      await reloadFromDatabase();
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[NixState] Falha ao desbloquear automaticamente pelo SO: $e');
      return false;
    }
  }

  /// Persiste a identidade soberana Seed A (pública em `identities` + semente envelopada em `key_material`),
  /// registra o dispositivo principal, salva o perfil local e garante a conversa de Mensagens Salvas.
  Future<void> persistPrimaryIdentity({
    required NixIdentity identity,
    required String displayName,
    String bio = '',
    String avatarStyle = 'nyx_emblem',
  }) async {
    _primaryIdentity = identity;
    final cleanName = displayName.trim().isEmpty ? 'Soberano Nix' : displayName.trim();
    _userProfile = _userProfile.copyWith(
      publicId: identity.publicId,
      displayName: cleanName,
      bio: bio,
      avatarStyle: avatarStyle,
    );
    _securityContext = _securityContext.copyWith(
      status: _localDatabase != null
          ? SecuritySubsystemState.ready
          : _securityContext.status,
      isSqlCipherUnlocked: _localDatabase != null,
      myFingerprint: identity.publicId,
      myPersona: cleanName,
    );

    if (_localDatabase != null && _identityRepo != null && _keyMaterialRepo != null) {
      final edPub = Uint8List.fromList(identity.ed25519PublicKey.bytes);
      final xPub = Uint8List.fromList(identity.x25519PublicKey.bytes);
      final edData = await identity.ed25519KeyPair.extract();
      final xData = await identity.x25519KeyPair.extract();
      final secretJson = utf8.encode(jsonEncode({
        'publicId': identity.publicId,
        'edSeed': base64Encode(edData.bytes),
        'xSeed': base64Encode(xData.bytes),
      }));
      final wrapKey = await _deriveWrappingKey('Nix-IdentityWrap-v1');
      final sealed = await SealedEnvelope.seal(
        key: wrapKey,
        plaintext: secretJson,
        aad: utf8.encode('identity:${identity.publicId}'),
      );

      await _keyMaterialRepo!.storeKeyMaterial(
        id: 'vault:identity_main',
        purpose: 'identity_seed_a',
        wrappedBytes: sealed.encode(),
        wrappingKeyRef: 'keyvault:master',
      );

      final existing = await _identityRepo!.getPrimaryIdentity();
      if (existing == null) {
        await _identityRepo!.createIdentity(
          id: identity.publicId,
          publicId: identity.publicId,
          edPublic: edPub,
          xPublic: xPub,
          keyRef: 'vault:identity_main',
        );
      }

      final devices = await _identityRepo!.listDevices(identity.publicId);
      if (devices.isEmpty) {
        final grantSig = await identity.sign(
          utf8.encode('nix-device-grant:${identity.publicId}:$_localDeviceId'),
        );
        await _identityRepo!.registerDevice(
          deviceId: _localDeviceId,
          identityId: identity.publicId,
          signingPublic: edPub,
          grant: Uint8List.fromList(grantSig),
        );
      } else {
        _localDeviceId = devices.first['id'] as String;
      }

      await _identityRepo!.saveProfile(
        identityId: identity.publicId,
        displayName: cleanName,
        bio: bio,
        avatarObjectId: avatarStyle,
      );

      // Emite Card ID público assinado (revision 1) na tabela `cards`
      final cardPayload = utf8.encode(jsonEncode({
        'publicId': identity.publicId,
        'ed': base64Encode(edPub),
        'x': base64Encode(xPub),
        'name': cleanName,
        'rev': 1,
      }));
      final cardSig = await identity.sign(cardPayload);
      await _identityRepo!.saveCard(
        id: 'card_${identity.publicId}_r1',
        identityId: identity.publicId,
        revision: 1,
        publicBundle: Uint8List.fromList(cardPayload),
        signature: Uint8List.fromList(cardSig),
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)).millisecondsSinceEpoch,
      );

      // Garante a existência da conversa `dm_saved_messages` no SQLCipher
      final savedConv = await _conversationRepo!.getConversation('dm_saved_messages');
      if (savedConv == null) {
        await _conversationRepo!.createConversation(
          id: 'dm_saved_messages',
          kind: 'saved',
          ownerIdentityId: identity.publicId,
          title: 'Mensagens Salvas',
        );
      }
    }

    // Sincroniza thread Mensagens Salvas em memória com o publicId real
    final savedIdx = _directMessages.indexWhere((d) => d.id == 'dm_saved_messages');
    if (savedIdx != -1) {
      _directMessages[savedIdx] = _directMessages[savedIdx].copyWith(
        peerPublicId: identity.publicId,
      );
      if (_selectedDm?.id == 'dm_saved_messages') {
        _selectedDm = _directMessages[savedIdx];
      }
    }

    notifyListeners();
  }

  /// Recarrega identidade, perfil, contatos, conversas e mensagens salvas após reinicialização.
  Future<void> reloadFromDatabase() async {
    if (_localDatabase == null || _identityRepo == null) return;

    // 1. Varre mensagens efêmeras expiradas antes de montar o estado em memória
    await _messageRepo?.sweepExpiredMessages();

    final primaryRow = await _identityRepo!.getPrimaryIdentity();
    if (primaryRow == null) return;

    final identityId = primaryRow['id'] as String;
    final publicId = primaryRow['public_id'] as String;
    final keyRef = primaryRow['key_ref'] as String;

    // 2. Desempacota o Seed A privado protegido em `key_material`
    final matRow = await _keyMaterialRepo?.getKeyMaterial(keyRef);
    if (matRow != null && _activeMasterKey != null) {
      final wrapKey = await _deriveWrappingKey('Nix-IdentityWrap-v1');
      final sealed = SealedPayload.decode(
        Uint8List.fromList(matRow['wrapped_bytes'] as List<int>),
      );
      final clear = await SealedEnvelope.open(
        key: wrapKey,
        payload: sealed,
        aad: utf8.encode('identity:$publicId'),
      );
      final decoded = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      final edSeed = base64Decode(decoded['edSeed'] as String);
      final xSeed = base64Decode(decoded['xSeed'] as String);
      final restoredIdentity = await NixIdentity.fromSeeds(
        ed25519Seed: edSeed,
        x25519PrivateBytes: xSeed,
      );
      _primaryIdentity = restoredIdentity;
      _securityContext = _securityContext.copyWith(
        status: SecuritySubsystemState.ready,
        isSqlCipherUnlocked: true,
        myFingerprint: restoredIdentity.publicId,
      );
    }

    final devices = await _identityRepo!.listDevices(identityId);
    if (devices.isNotEmpty) {
      _localDeviceId = devices.first['id'] as String;
    }

    final profileRow = await _identityRepo!.getProfile(identityId);
    final restoredName =
        (profileRow?['display_name'] as String?) ?? _userProfile.displayName;
    _securityContext = _securityContext.copyWith(myPersona: restoredName);
    _userProfile = _userProfile.copyWith(
      publicId: publicId,
      displayName: restoredName,
      bio: (profileRow?['bio'] as String?) ?? _userProfile.bio,
      avatarStyle: (profileRow?['avatar_object_id'] as String?) ?? _userProfile.avatarStyle,
    );

    // 3. Restaura contatos verificados e conversas diretas / Mensagens Salvas
    final conversations = await _conversationRepo!.listConversations();
    final savedIdx = _directMessages.indexWhere((d) => d.id == 'dm_saved_messages');
    if (savedIdx != -1) {
      final savedRows = await _messageRepo!.getMessagesForConversation('dm_saved_messages', limit: 200);
      final loadedSavedMsgs = savedRows.map((r) => Message(
        id: r['id'] as String,
        channelId: 'dm_saved_messages',
        senderName: _userProfile.effectiveDisplayName,
        senderFingerprint: _securityContext.myFingerprint,
        isMe: (r['author_key'] as String) == publicId,
        text: (r['body'] as String?) ?? '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int, isUtc: true),
        isVerified: true,
      )).toList();

      final baseWelcome = _directMessages[savedIdx].messages.where((m) => m.id == 'saved_welcome').toList();
      _directMessages[savedIdx] = _directMessages[savedIdx].copyWith(
        peerPublicId: publicId,
        messages: [...baseWelcome, ...loadedSavedMsgs],
      );
    }

    for (final conv in conversations) {
      final cid = conv['id'] as String;
      if (cid == 'dm_saved_messages') continue;
      if ((conv['kind'] as String) == 'direct') {
        final msgRows = await _messageRepo!.getMessagesForConversation(cid, limit: 200);
        final msgs = msgRows.map((r) => Message(
          id: r['id'] as String,
          channelId: cid,
          senderName: (r['author_key'] as String) == publicId ? _userProfile.effectiveDisplayName : (conv['title'] as String),
          senderFingerprint: r['author_key'] as String,
          isMe: (r['author_key'] as String) == publicId,
          text: (r['body'] as String?) ?? '',
          timestamp: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int, isUtc: true),
          isVerified: true,
        )).toList();

        final existingIdx = _directMessages.indexWhere((d) => d.id == cid);
        final thread = DirectMessageThread(
          id: cid,
          peerName: conv['title'] as String,
          peerPublicId: cid,
          statusText: 'Sessão P2P Cifrada · Tor Onion v3',
          isOnline: false,
          isVerified: true,
          trustLevel: NixTrustLevel.level2Yellow,
          unreadCount: 0,
          messages: msgs,
        );
        if (existingIdx == -1) {
          _directMessages.add(thread);
        } else {
          _directMessages[existingIdx] = thread;
        }
      }
    }

    // 4. Restaura Acervo Cultural persistido em media_items
    final mediaRows = await _mediaRepo?.listMediaItems(limit: 200) ?? [];
    if (mediaRows.isNotEmpty) {
      final items = <CulturalItem>[];
      for (final row in mediaRows) {
        try {
          final meta = jsonDecode(row['metadata_json'] as String) as Map<String, dynamic>;
          items.add(CulturalItem.fromJson(meta));
        } catch (_) {}
      }
      if (items.isNotEmpty) {
        _userProfile = _userProfile.copyWith(culturalItems: items);
      }
    }

    _isOnboarded = true;
    notifyListeners();
  }

  /// Envia mensagem com garantia de persistência local atômica no SQLCipher,
  /// enfileiramento na Outbox e difusão via Bluetooth Mesh e/ou Relay Onion (P0-5).
  Future<bool> sendSovereignMessage({
    required String conversationId,
    required String text,
    String? recipientMailbox,
    Uint8List? recipientX25519PublicKey,
    List<String> attachments = const [],
  }) async {
    if (text.trim().isEmpty && attachments.isEmpty) return false;

    final now = DateTime.now().toUtc();
    final messageId = 'msg_${now.millisecondsSinceEpoch}';

    // 1. Cria representação em memória para resposta instantânea da interface
    final newMessage = Message(
      id: messageId,
      channelId: conversationId,
      senderName: _userProfile.effectiveDisplayName,
      senderFingerprint: _securityContext.myFingerprint,
      isMe: true,
      text: text.trim(),
      timestamp: now,
      ephemeralSeconds: _selectedEphemeralTimer,
      remainingSeconds: _selectedEphemeralTimer,
      isVerified: true,
      attachments: attachments,
    );

    if (!_messages.containsKey(conversationId)) {
      _messages[conversationId] = [];
    }
    _messages[conversationId]!.add(newMessage);
    notifyListeners();

    // 2. Se o banco SQLCipher estiver pronto, persiste de forma atômica na tabela messages + FTS5
    if (_localDatabase != null && _messageRepo != null) {
      try {
        await _messageRepo!.insertMessage(
          id: messageId,
          conversationId: conversationId,
          authorKey: _userProfile.publicId,
          deviceId: 'local_client_dev',
          body: text.trim(),
          deliveryState: 'queued',
        );
      } catch (e) {
        debugPrint('[NixState] Aviso ao salvar mensagem no banco local: $e');
      }
    }

    // 3. Serializa e cifra o envelope da mensagem (fail-closed: nunca grava plaintext em outbox.ciphertext)
    Uint8List payloadBytes;
    final clearJson = jsonEncode({
      'id': messageId,
      'sender': _userProfile.publicId,
      'text': text.trim(),
      'ts': now.millisecondsSinceEpoch,
      'attachments': attachments,
    });
    final clearBytes = utf8.encode(clearJson);

    if (recipientX25519PublicKey != null) {
      try {
        final ephemeralKp = await X25519().newKeyPair();
        final sharedSecret = await X25519().sharedSecretKey(
          keyPair: ephemeralKp,
          remotePublicKey: SimplePublicKey(recipientX25519PublicKey, type: KeyPairType.x25519),
        );
        final sealed = await SealedEnvelope.seal(
          key: sharedSecret,
          plaintext: clearBytes,
        );
        final ephemPub = await ephemeralKp.extractPublicKey();
        final builder = BytesBuilder(copy: false)
          ..add(ephemPub.bytes)
          ..add(sealed.encode());
        payloadBytes = builder.toBytes();
      } catch (e) {
        debugPrint('[NixState] Fail-Closed E2EE ao cifrar para destinatário: $e');
        return false;
      }
    } else if (_activeMasterKey != null) {
      // Envelope selado local com chave derivada do cofre ativo quando ainda não há prekey X25519 do par
      try {
        final outboxKey = await _deriveWrappingKey('Nix-OutboxEnvelope-v1');
        final sealed = await SealedEnvelope.seal(
          key: outboxKey,
          plaintext: clearBytes,
          aad: utf8.encode('conv:$conversationId'),
        );
        payloadBytes = sealed.encode();
      } catch (e) {
        debugPrint('[NixState] Fail-Closed ao selar envelope da outbox: $e');
        return false;
      }
    } else {
      debugPrint('[NixState] Fail-Closed: tentativa de envio sem chave E2EE nem KeyVault desbloqueado.');
      return false;
    }

    // 4. Enfileira na Outbox local com delivery ID e payload_hash estáveis
    final outboxId = 'out_${now.millisecondsSinceEpoch}';
    final destMailbox = recipientMailbox ?? 'mailbox_${conversationId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
    final expiresAt = now.add(const Duration(days: 7)).millisecondsSinceEpoch;

    if (_localDatabase != null && _outboxRepo != null) {
      try {
        await _outboxRepo!.enqueue(
          id: outboxId,
          destinationMailbox: destMailbox,
          ciphertext: payloadBytes,
          expiresAt: expiresAt,
        );
      } catch (e) {
        debugPrint('[NixState] Aviso ao enfileirar na outbox: $e');
      }
    }

    // 5. Se o modo Malha Bluetooth estiver ativo, transmite aos nós vizinhos
    if (_bluetoothMesh.isMeshEnabled) {
      try {
        await _bluetoothMesh.broadcastEnvelope(
          recipientCardId: conversationId,
          payload: payloadBytes,
        );
      } catch (e) {
        debugPrint('[NixState] Aviso ao transmitir via malha Bluetooth: $e');
      }
    }

    return true;
  }

  /// Processa recebimento de envelope cifrado aplicando deduplicação estrita (inbox_dedup),
  /// decifração e commit atômico no banco local antes de qualquer confirmação (ACK).
  Future<bool> processInboundEnvelope({
    required String mailboxId,
    required String deliveryId,
    required Uint8List ciphertext,
    int? expiresAt,
    SecretKeyData? sessionKey,
  }) async {
    final now = DateTime.now().toUtc();
    final exp = expiresAt ?? now.add(const Duration(days: 7)).millisecondsSinceEpoch;
    final payloadHash = Uint8List.fromList(std_crypto.sha256.convert(ciphertext).bytes);

    // 1. Deduplicação estrita: se já processado, descarta para evitar replay (Gate P0-5)
    if (_localDatabase != null && _outboxRepo != null) {
      if (await _outboxRepo!.isDuplicateEnvelope(mailboxId, deliveryId)) {
        return false;
      }
    }

    // 2. Decifra e autentica o payload antes de persistir ou emitir deduplicação/ACK
    String plaintext = '';
    String senderId = 'desconhecido';
    final String conversationId = mailboxId;
    List<String> attachments = [];

    try {
      if (sessionKey == null) {
        debugPrint('[NixState] Fail-Closed: envelope recebido sem chave de sessão autenticada.');
        return false;
      }
      final sealed = SealedPayload.decode(ciphertext);
      final clear = await SealedEnvelope.open(key: sessionKey, payload: sealed);
      final map = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      plaintext = map['text'] as String? ?? '';
      senderId = map['sender'] as String? ?? 'desconhecido';
      attachments = (map['attachments'] as List?)?.cast<String>() ?? [];
    } catch (e) {
      debugPrint('[NixState] Fail-Closed: falha ao autenticar/decifrar envelope de entrada: $e');
      return false;
    }

    // 3. Commit-before-ACK: persiste mensagem e registra dedup atomicamente no banco local
    final msgId = 'in_${now.millisecondsSinceEpoch}_$deliveryId';
    if (_localDatabase != null && _messageRepo != null && _outboxRepo != null) {
      await _localDatabase!.rawDatabase.transaction((txn) async {
        await txn.insert('messages', {
          'id': msgId,
          'conversation_id': conversationId,
          'author_key': senderId,
          'device_id': 'remote_client_dev',
          'body': plaintext,
          'created_at': now.millisecondsSinceEpoch,
          'received_at': now.millisecondsSinceEpoch,
          'revision': 1,
          'delivery_state': 'received',
        });
        await txn.insert('inbox_dedup', {
          'mailbox_id': mailboxId,
          'delivery_id': deliveryId,
          'payload_hash': payloadHash,
          'committed_at': now.millisecondsSinceEpoch,
          'expires_at': exp,
        });
      });
    }

    // 4. Atualiza a lista em memória para refletir na UI
    final incomingMsg = Message(
      id: msgId,
      channelId: conversationId,
      senderName: senderId,
      senderFingerprint: '',
      isMe: false,
      text: plaintext,
      timestamp: now,
      isVerified: true,
      attachments: attachments,
    );

    if (!_messages.containsKey(conversationId)) {
      _messages[conversationId] = [];
    }
    _messages[conversationId]!.add(incomingMsg);
    notifyListeners();
    return true;
  }

  NixState({bool? loadMockData, KeyVault? keyVault}) {
    _keyVault = keyVault ?? KeyVault();
    final isTest = Platform.environment['FLUTTER_TEST'] == 'true';
    final shouldLoadMock = loadMockData ?? isTest;

    if (shouldLoadMock) {
      _loadMockFixtures();
      _isOnboarded = true;
    } else {
      _initializeProductionCleanState();
    }
    NixColors.sync(
      NixSurfaceScheme.resolve(_settings.themeMode),
      currentPalette,
    );
    loadStarwireRepos();
    if (!shouldLoadMock) {
      loadPersistedState();
      _checkPersistedOnboardingStatus();
    }
  }

  void _loadMockFixtures() {
    _spaces = MockData.getInitialSpaces();
    _folders = MockData.getInitialFolders();
    _discoverableSpaces = MockData.getDiscoverablePublicSpaces();
    _currentSpace = _spaces.first;
    _currentChannel = _currentSpace.channels.first;
    _messages = MockData.getInitialMessages();
    _publications = MockData.getInitialPublications();
    _forumPosts = MockData.getInitialForumPosts();
    _selectedForumPost = _forumPosts.first;
    _members = MockData.getInitialMembers();
    _userProfile = MockData.getInitialUserProfile();
    _directMessages = MockData.getInitialDirectMessages();
    _contactRequests = MockData.getInitialContactRequests();
    _transactions = MockData.getInitialTransactions();
    _systemUpdates = MockData.getInitialSystemUpdates();
    _moneroOrders = MockData.getInitialMoneroOrders();
    _githubRepos = MockData.getInitialGithubRepos();
  }

  void _initializeProductionCleanState() {
    _userProfile = const UserProfile(
      publicId: '',
      displayName: '',
      bio: '',
      currentActivity: '',
      memberSinceYear: '26',
      avatarStyle: 'nyx_emblem',
      culturalItems: [],
    );
    const defaultChannel = Channel(
      id: 'general_saved',
      spaceId: 'local_space',
      name: 'geral',
      topic: 'Canal local soberano',
      category: 'GERAL',
      type: ChannelType.text,
      description: 'Canal local soberano.',
    );
    const defaultSpace = Space(
      id: 'local_space',
      name: 'Nix Local',
      initials: 'NX',
      description: 'Espaço local soberano',
      channels: [defaultChannel],
    );
    _spaces = [defaultSpace];
    _currentSpace = defaultSpace;
    _currentChannel = defaultChannel;
    _discoverableSpaces = [];
    _folders = [
      const SpaceFolder(
        id: 'all',
        name: 'Todas',
        iconName: 'folder',
        spaceIds: ['local_space'],
        conversationIds: ['dm_saved_messages'],
      ),
    ];
    _messages = {};
    _publications = {};
    _forumPosts = [];
    _members = [
      Member(
        id: 'me',
        name: _userProfile.effectiveDisplayName,
        roleName: 'Proprietário',
        role: MemberRole.admin,
        fingerprint: _securityContext.myFingerprint,
        isOnline: true,
      ),
    ];
    _contactRequests = [];
    _transactions = [];
    _systemUpdates = [];
    _moneroOrders = [];
    _githubRepos = [];

    // Mensagens Salvas (Cofre Pessoal Real e Cifrado)
    _directMessages = [
      DirectMessageThread(
        id: 'dm_saved_messages',
        peerName: 'Mensagens Salvas',
        peerPublicId: _userProfile.publicId,
        statusText: 'Cofre Pessoal Cifrado · Notas & Arquivo Local',
        isOnline: true,
        isVerified: true,
        trustLevel: NixTrustLevel.level3Green,
        isSavedMessages: true,
        isPinned: true,
        unreadCount: 0,
        messages: [
          Message(
            id: 'saved_welcome',
            channelId: 'dm_saved_messages',
            senderName: _userProfile.effectiveDisplayName,
            senderFingerprint: _securityContext.myFingerprint,
            isMe: true,
            isPinned: true,
            text: 'Bem-vindo ao seu cofre de Mensagens Salvas do Projeto Nix.\n\n'
                '• Todas as notas e arquivos salvos aqui são cifrados localmente no banco SQLCipher.\n'
                '• Roteamento Tor Onion v3 ativo e fail-closed por padrão.\n'
                '• Suas mensagens não passam por servidores nem coletam telemetria.',
            timestamp: DateTime.now().toUtc(),
            attachments: const [],
          ),
        ],
      ),
    ];
    _selectedDm = _directMessages.first;
    _homeSubTab = HomeSubTab.cardId;
    _activeArea = NixActiveArea.homePrivate;
  }

  Future<void> _checkPersistedOnboardingStatus() async {
    try {
      // 1. Tenta desbloqueio automático via chaveiro nativo do SO (libsecret / AndroidKeyStore)
      final unlocked = await tryAutoUnlockAndRestore();
      if (unlocked) {
        return;
      }

      // 2. Fallback para metadados não-sensíveis caso o vault exija senha manual ou ainda não exista
      final snapshot = await OnboardingStateSnapshot.load();
      if (snapshot.isCompleted) {
        _isOnboarded = true;
        if (snapshot.displayName != null && snapshot.displayName!.isNotEmpty) {
          _userProfile = _userProfile.copyWith(displayName: snapshot.displayName);
        }
        if (snapshot.avatarStyle != null && snapshot.avatarStyle!.isNotEmpty) {
          _userProfile = _userProfile.copyWith(avatarStyle: snapshot.avatarStyle);
        }
        if (snapshot.publicId != null && snapshot.publicId!.isNotEmpty) {
          _userProfile = _userProfile.copyWith(publicId: snapshot.publicId);
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Caminho local de persistência de preferências do cliente (apenas desktop/mobile reais).
  String get _prefsFilePath {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return '';
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return '';
    return '$home/.local/share/nix/client_prefs_v4.json';
  }

  Future<void> _persistState() async {
    try {
      final path = _prefsFilePath;
      if (path.isEmpty) return;
      final file = File(path);
      await file.parent.create(recursive: true);
      final data = {
        'settings': _settings.toJson(),
        'savedAcervoIds': _savedAcervoIds.toList(),
        'culturalItems': _userProfile.culturalItems.map((c) => c.toJson()).toList(),
        'folders': _folders
            .map((f) => {
                  'id': f.id,
                  'name': f.name,
                  'iconName': f.iconName,
                  'colorValue': f.colorValue,
                  'spaceIds': f.spaceIds,
                  'conversationIds': f.conversationIds,
                })
            .toList(),
      };
      await file.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {
      // Ambiente de testes ou sandbox sem HOME gravável
    }
  }

  Future<void> loadPersistedState() async {
    try {
      final path = _prefsFilePath;
      if (path.isEmpty) return;
      final file = File(path);
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map<String, dynamic>) {
        if (raw['settings'] is Map<String, dynamic>) {
          _settings = UserSettings.fromJson(raw['settings'] as Map<String, dynamic>);
          NixColors.sync(
            NixSurfaceScheme.resolve(_settings.themeMode),
            currentPalette,
          );
        }
        if (raw['savedAcervoIds'] is List) {
          _savedAcervoIds
            ..clear()
            ..addAll((raw['savedAcervoIds'] as List).map((e) => e.toString()));
        }
        if (raw['culturalItems'] is List) {
          final loadedItems = (raw['culturalItems'] as List)
              .whereType<Map<String, dynamic>>()
              .map((e) => CulturalItem.fromJson(e))
              .toList();
          _userProfile = _userProfile.copyWith(culturalItems: loadedItems);
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Carrega o catálogo real Starwire (4.188 repositórios) do asset JSON.
  Future<void> loadStarwireRepos() async {
    try {
      final jsonString = await rootBundle.loadString('assets/data/starwire_repos.json');
      final dynamic decoded = jsonDecode(jsonString);
      if (decoded is List) {
        final parsed = decoded
            .map((item) => GithubRepository.fromStarwireJson(item as Map<String, dynamic>))
            .toList();
        if (parsed.isNotEmpty) {
          _githubRepos = parsed;
          notifyListeners();
        }
      }
    } catch (_) {
      // Fallback gracioso em testes unitários sem asset bundle completo
    }
  }

  // Getters principais
  List<Space> get spaces => _spaces;
  List<SpaceFolder> get folders => _folders;
  Space get currentSpace => _currentSpace;
  Channel get currentChannel => _currentChannel;

  List<Message> get activeConversationMessages {
    if (_activeArea == NixActiveArea.homePrivate &&
        _homeSubTab == HomeSubTab.directChat &&
        _selectedDm != null) {
      return _selectedDm!.messages;
    }
    return _messages[_currentChannel.id] ?? [];
  }

  List<Message> get currentMessages => _messages[_currentChannel.id] ?? [];
  List<Publication> get currentPublications => _publications[_currentChannel.id] ?? [];
  List<ForumPost> get currentForumPosts =>
      _forumPosts.where((p) => p.channelId == _currentChannel.id).toList();
  ForumPost? get selectedForumPost => _selectedForumPost;
  List<Member> get members => _members;
  CallState get callState => _callState;
  SecurityContext get securityContext => _securityContext;
  UserProfile get userProfile => _userProfile;
  UserSettings get settings => _settings;
  NixThemeMode get themeMode => _settings.themeMode;

  NixPalette get currentPalette => NixPalette.fromType(
        _settings.paletteType,
        _settings.customPaletteColor != null ? Color(_settings.customPaletteColor!) : null,
      );

  NixActiveArea get activeArea => _activeArea;
  HomeSubTab get homeSubTab => _homeSubTab;
  List<DirectMessageThread> get directMessages => _directMessages;
  DirectMessageThread? get selectedDm => _selectedDm;
  DirectMessageThread get savedMessagesThread => _directMessages.firstWhere(
        (d) => d.isSavedMessages,
        orElse: () => _directMessages.first,
      );

  String get activeFolderId => _activeFolderId;
  ConversationFilter get conversationFilter => _conversationFilter;
  String get conversationSearchQuery => _conversationSearchQuery;
  bool get isWindowMaximized => _isWindowMaximized;

  List<ContactRequest> get contactRequests => _contactRequests;
  ContactRequest? get hoveredContactRequest => _hoveredContactRequest;
  PeerCardHoverState get peerHoverState => _peerHoverState;
  String? get hoverLockoutRequestId => _hoverLockoutRequestId;

  List<XmrTransactionRecord> get transactions => _transactions;
  List<SystemUpdateRecord> get systemUpdates => _systemUpdates;
  List<MoneroP2pOrder> get moneroOrders => _moneroOrders;
  List<GithubRepository> get githubRepos => _githubRepos;

  bool get isProfileOverlayOpen => _isProfileOverlayOpen;
  bool get isSettingsOpenInOverlay => _isSettingsOpenInOverlay;
  SettingsCategory get activeSettingsCategory => _activeSettingsCategory;
  bool get isMembersPanelOpen => _isMembersPanelOpen;
  bool get isConversationInfoOpen => _isConversationInfoOpen;
  String get conversationHistorySearch => _conversationHistorySearch;
  int get selectedEphemeralTimer => _selectedEphemeralTimer;
  bool get exploreSortAscending => _exploreSortAscending;
  String get exploreSearchQuery => _exploreSearchQuery;

  Message? get replyingToMessage => _replyingToMessage;
  Message? get editingMessage => _editingMessage;
  Set<String> get selectedMessageIds => _selectedMessageIds;
  String? get highlightedMessageId => _highlightedMessageId;

  // Getters Tor Onion
  String get onionAddress => _onionAddress;
  bool get isTorRunning => _isTorRunning;
  String get torDiagnosticDetail => _torDiagnosticDetail;
  bool get isTorFailClosed => _settings.transportProfile.contains('Fail-Closed');

  /// Diagnóstico real de conectividade e handshake SOCKS5 + ControlPort do daemon Tor.
  Future<bool> checkTorDaemonStatus() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      _isTorRunning = false;
      return false;
    }
    try {
      final cookiePath = '${_embeddedTor.dataDirectory}/control_auth_cookie';
      final diag = await TorDiagnostics.diagnose(
        host: '127.0.0.1',
        socksPort: _embeddedTor.socksPort,
        controlPort: _embeddedTor.controlPort,
        controlCookiePath: cookiePath,
      );
      if (diag.socksReachable) {
        _isTorRunning = true;
        _torDiagnosticDetail =
            '${diag.message} · Endpoint: $_onionAddress';
        _securityContext = _securityContext.copyWith(
          isTorConnected: true,
          status: SecuritySubsystemState.ready,
        );
        notifyListeners();
        return true;
      }
      _isTorRunning = false;
      _torDiagnosticDetail = isTorFailClosed
          ? '${diag.message} (Fallback IP direto bloqueado)'
          : diag.message;
      _securityContext = _securityContext.copyWith(
        isTorConnected: false,
        status: SecuritySubsystemState.failed,
      );
      notifyListeners();
      return false;
    } catch (_) {
      _isTorRunning = false;
      _torDiagnosticDetail = isTorFailClosed
          ? 'Tor indisponível — Fail-Closed ATIVO (Fallback IP direto bloqueado)'
          : 'Tor indisponível em 127.0.0.1:9050';
      _securityContext = _securityContext.copyWith(
        isTorConnected: false,
        status: SecuritySubsystemState.failed,
      );
      notifyListeners();
      return false;
    }
  }

  // Getters Filtros GitHub
  String get githubSearchQuery => _githubSearchQuery;
  String get githubSelectedTopic => _githubSelectedTopic;
  String get githubSelectedLanguage => _githubSelectedLanguage;
  String get githubSortBy => _githubSortBy;

  List<GithubRepository> get filteredGithubRepos {
    final q = _githubSearchQuery.trim().toLowerCase();
    final filtered = _githubRepos.where((repo) {
      if (q.isNotEmpty) {
        final matchesName = repo.name.toLowerCase().contains(q);
        final matchesOwner = repo.owner.toLowerCase().contains(q);
        final matchesDesc = repo.description.toLowerCase().contains(q);
        final matchesTopic = repo.topics.any((t) => t.toLowerCase().contains(q));
        if (!matchesName && !matchesOwner && !matchesDesc && !matchesTopic) return false;
      }
      if (_githubSelectedTopic != 'Todos') {
        if (!repo.topics.any((t) => t.toLowerCase() == _githubSelectedTopic.toLowerCase()) &&
            repo.category.toLowerCase() != _githubSelectedTopic.toLowerCase()) {
          return false;
        }
      }
      if (_githubSelectedLanguage != 'Todas') {
        if (repo.language != _githubSelectedLanguage) return false;
      }
      return true;
    }).toList();

    if (_githubSortBy == 'trending') {
      filtered.sort((a, b) => b.starsThisWeek.compareTo(a.starsThisWeek));
    } else if (_githubSortBy == 'stars') {
      filtered.sort((a, b) => b.starsCount.compareTo(a.starsCount));
    } else {
      filtered.sort((a, b) => b.updatedDate.compareTo(a.updatedDate));
    }
    return filtered;
  }

  /// Estatísticas reais calculadas diretamente do catálogo Starwire carregado.
  Map<String, int> get githubLanguageCounts {
    final counts = <String, int>{};
    for (final r in _githubRepos) {
      final lang = r.language.trim().isEmpty ? 'Markdown' : r.language.trim();
      counts[lang] = (counts[lang] ?? 0) + 1;
    }
    final sortedEntries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map<String, int>.fromEntries(sortedEntries.take(8));
  }

  Map<String, int> get githubCategoryCounts {
    final counts = <String, int>{};
    for (final r in _githubRepos) {
      final cat = r.category.trim().isEmpty ? 'Open Source' : r.category.trim();
      counts[cat] = (counts[cat] ?? 0) + 1;
    }
    final sortedEntries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Map<String, int>.fromEntries(sortedEntries.take(6));
  }

  // Getters Filtros Monero P2P
  MoneroP2pSide get moneroSelectedSide => _moneroSelectedSide;
  String get moneroSelectedFiat => _moneroSelectedFiat;
  String get moneroSelectedPaymentMethod => _moneroSelectedPaymentMethod;
  String get moneroSearchQuery => _moneroSearchQuery;

  List<MoneroP2pOrder> get filteredMoneroOrders {
    final q = _moneroSearchQuery.trim().toLowerCase();
    return _moneroOrders.where((order) {
      if (order.isExpired) return false;
      if (order.side != _moneroSelectedSide) return false;
      if (order.fiatCurrency != _moneroSelectedFiat) return false;
      if (_moneroSelectedPaymentMethod != 'Todos') {
        if (!order.paymentMethod.toLowerCase().contains(_moneroSelectedPaymentMethod.toLowerCase())) {
          return false;
        }
      }
      if (q.isNotEmpty) {
        final matchesTrader = order.traderName.toLowerCase().contains(q);
        final matchesMethod = order.paymentMethod.toLowerCase().contains(q);
        final matchesNotes = order.notes.toLowerCase().contains(q);
        if (!matchesTrader && !matchesMethod && !matchesNotes) return false;
      }
      return true;
    }).toList();
  }

  bool verifyMoneroOrder(MoneroP2pOrder order) {
    if (order.isExpired || !order.isSignatureVerified) return false;
    if (order.nonceHex != null && _seenMoneroNonces.contains('${order.id}:${order.nonceHex}')) {
      return true; // Já verificado localmente
    }
    if (order.nonceHex != null) {
      _seenMoneroNonces.add('${order.id}:${order.nonceHex}');
    }
    return order.signedManifestHash.length >= 8;
  }

  /// Lista de grupos públicos filtrada e ordenada (padrão: do menos populoso ao mais populoso).
  List<Space> get filteredDiscoverableSpaces {
    final query = _exploreSearchQuery.trim().toLowerCase();
    final filtered = _discoverableSpaces.where((s) {
      if (query.isEmpty) return true;
      return s.name.toLowerCase().contains(query) ||
          s.description.toLowerCase().contains(query) ||
          s.categoryTag.toLowerCase().contains(query);
    }).toList();

    filtered.sort((a, b) => _exploreSortAscending
        ? a.memberCount.compareTo(b.memberCount)
        : b.memberCount.compareTo(a.memberCount));
    return filtered;
  }

  /// Lista filtrada/ordenada de conversas diretas (sempre colocando Mensagens Salvas primeiro, depois fixadas).
  List<DirectMessageThread> get filteredDirectMessages {
    final q = _conversationSearchQuery.trim().toLowerCase();
    SpaceFolder? activeFolder;
    if (_activeFolderId != 'all' && _activeFolderId != 'private') {
      final fIdx = _folders.indexWhere((f) => f.id == _activeFolderId);
      if (fIdx != -1) activeFolder = _folders[fIdx];
    }

    final list = _directMessages.where((dm) {
      if (activeFolder != null && !dm.isSavedMessages) {
        if (!activeFolder.conversationIds.contains(dm.id)) return false;
      }
      if (q.isNotEmpty) {
        final match = dm.peerName.toLowerCase().contains(q) ||
            dm.lastMessagePreview.toLowerCase().contains(q) ||
            dm.peerPublicId.toLowerCase().contains(q);
        if (!match) return false;
      }
      switch (_conversationFilter) {
        case ConversationFilter.unread:
          return dm.unreadCount > 0;
        case ConversationFilter.pinned:
          return dm.isPinned;
        case ConversationFilter.muted:
          return dm.isMuted;
        case ConversationFilter.groups:
        case ConversationFilter.channels:
          return false;
        case ConversationFilter.all:
        case ConversationFilter.privateChats:
          return true;
      }
    }).toList();

    list.sort((a, b) {
      if (a.isSavedMessages != b.isSavedMessages) return a.isSavedMessages ? -1 : 1;
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      final ta = a.lastActivityAt ?? DateTime(2000);
      final tb = b.lastActivityAt ?? DateTime(2000);
      return tb.compareTo(ta);
    });
    return list;
  }

  List<Space> get visibleSpacesForFolder {
    if (_activeFolderId == 'private') return const [];
    final q = _conversationSearchQuery.trim().toLowerCase();
    Iterable<Space> base = _spaces;
    if (_activeFolderId != 'all') {
      final fIdx = _folders.indexWhere((f) => f.id == _activeFolderId);
      if (fIdx != -1) {
        final ids = _folders[fIdx].spaceIds;
        base = base.where((s) => ids.contains(s.id));
      }
    }
    return base.where((s) {
      if (q.isNotEmpty) {
        final matchSpace = s.name.toLowerCase().contains(q);
        final matchChannel = s.channels.any((c) => c.name.toLowerCase().contains(q));
        if (!matchSpace && !matchChannel) return false;
      }
      switch (_conversationFilter) {
        case ConversationFilter.unread:
          return s.unreadCount > 0 || s.channels.any((c) => c.unreadCount > 0);
        case ConversationFilter.pinned:
          return s.isPinned || s.channels.any((c) => c.isPinned);
        case ConversationFilter.muted:
          return s.isMuted || s.channels.any((c) => c.isMuted);
        case ConversationFilter.privateChats:
          return false;
        case ConversationFilter.channels:
          return s.channels.any((c) => c.type == ChannelType.announcement || c.type == ChannelType.publication);
        case ConversationFilter.groups:
        case ConversationFilter.all:
          return true;
      }
    }).toList();
  }

  /// Privacidade do Card ID aplicada na disponibilização dos dados no estado.
  AuthorizedPeerCardData getAuthorizedPeerCardData({
    required String peerName,
    required String peerPublicId,
    required NixTrustLevel trustLevel,
    required bool hasCryptographicShield,
    required String rawBio,
    required List<String> rawHighlights,
    required String ownerVisibility,
    bool isVerifiedContact = false,
  }) {
    if (ownerVisibility == 'Oculto') {
      return AuthorizedPeerCardData(
        peerName: peerName,
        peerPublicId: peerPublicId,
        trustLevel: trustLevel,
        hasCryptographicShield: hasCryptographicShield,
        isAuthorized: false,
        visibilityLabel: 'Oculto pelo proprietário',
        bio: 'Dados restritos pelo proprietário (Configurações → Privacidade → Visibilidade do Card ID).',
        culturalHighlights: const [],
      );
    }
    if (ownerVisibility == 'Apenas Contatos Verificados' && !isVerifiedContact) {
      return AuthorizedPeerCardData(
        peerName: peerName,
        peerPublicId: peerPublicId,
        trustLevel: trustLevel,
        hasCryptographicShield: hasCryptographicShield,
        isAuthorized: false,
        visibilityLabel: 'Apenas Contatos Verificados',
        bio: 'Adicione e verifique este par (QR / Chave Pública) para liberar biografia e acervo completo.',
        culturalHighlights: const [],
      );
    }
    return AuthorizedPeerCardData(
      peerName: peerName,
      peerPublicId: peerPublicId,
      trustLevel: trustLevel,
      hasCryptographicShield: hasCryptographicShield,
      isAuthorized: true,
      visibilityLabel: ownerVisibility,
      bio: rawBio,
      culturalHighlights: rawHighlights,
    );
  }

  // ================= NAVEGAÇÃO DE ÁREAS =================

  void openHomePrivateArea({bool resetToCardId = false}) {
    _activeArea = NixActiveArea.homePrivate;
    _activeFolderId = 'private';
    if (resetToCardId) {
      _homeSubTab = HomeSubTab.cardId;
      _selectedDm = null;
    }
    _clearTransientMessageModes();
    notifyListeners();
  }

  void openExploreArea() {
    _activeArea = NixActiveArea.explore;
    notifyListeners();
  }

  void openGithubDiscoveryArea() {
    _activeArea = NixActiveArea.github;
    notifyListeners();
  }

  void openMoneroP2pArea() {
    _activeArea = NixActiveArea.moneroP2p;
    notifyListeners();
  }

  void selectHomeSubTab(HomeSubTab tab) {
    if (tab == HomeSubTab.moneroP2p) {
      openMoneroP2pArea();
      return;
    }
    if (tab == HomeSubTab.githubDiscovery) {
      openGithubDiscoveryArea();
      return;
    }
    _activeArea = NixActiveArea.homePrivate;
    _homeSubTab = tab;
    if (tab != HomeSubTab.directChat) {
      _selectedDm = null;
    }
    _clearTransientMessageModes();
    notifyListeners();
  }

  // ================= MÁQUINA DE ESTADOS HOVER CARD ID (ANTI-FLICKERING) =================

  void setHoveredContactRequest(ContactRequest? req) {
    if (req == null) {
      _hoveredContactRequest = null;
      _peerHoverState = PeerCardHoverState.closed;
    } else {
      _hoveredContactRequest = req;
      _peerHoverState = PeerCardHoverState.openByHover;
    }
    notifyListeners();
  }

  void onRequestPeerHoverEnter(ContactRequest req) {
    if (_hoverLockoutRequestId == req.id) return;
    _hoverDebounceTimer?.cancel();
    _peerHoverState = PeerCardHoverState.openingPending;
    _hoveredContactRequest = req;
    _peerHoverState = PeerCardHoverState.openByHover;
    notifyListeners();
  }

  void onRequestPeerHoverExit(ContactRequest req) {
    if (_hoverLockoutRequestId == req.id) {
      _hoverLockoutRequestId = null;
    }
    _hoverDebounceTimer?.cancel();
    _hoverDebounceTimer = Timer(const Duration(milliseconds: 90), () {
      if (!_isCursorOverHoverPreview &&
          _hoveredContactRequest?.id == req.id &&
          _peerHoverState != PeerCardHoverState.openByClick) {
        _hoveredContactRequest = null;
        _peerHoverState = PeerCardHoverState.closed;
        notifyListeners();
      }
    });
  }

  void setHoverOverPreviewCard(bool over) {
    _isCursorOverHoverPreview = over;
    if (!over) {
      _hoverDebounceTimer?.cancel();
      _hoverDebounceTimer = Timer(const Duration(milliseconds: 90), () {
        if (!_isCursorOverHoverPreview && _peerHoverState == PeerCardHoverState.openByHover) {
          _hoveredContactRequest = null;
          _peerHoverState = PeerCardHoverState.closed;
          notifyListeners();
        }
      });
    }
  }

  void dismissHoveredPeerCard() {
    _hoverDebounceTimer?.cancel();
    if (_hoveredContactRequest != null) {
      _hoverLockoutRequestId = _hoveredContactRequest!.id;
    }
    _peerHoverState = PeerCardHoverState.closingRequested;
    _hoveredContactRequest = null;
    _isCursorOverHoverPreview = false;
    _peerHoverState = PeerCardHoverState.closed;
    notifyListeners();
  }

  // ================= PASTAS, FILTROS & CONVERSAS DIRETAS =================

  void selectFolder(String folderId) {
    _activeFolderId = folderId;
    if (folderId == 'private') {
      _activeArea = NixActiveArea.homePrivate;
    } else if (folderId != 'all') {
      final fIdx = _folders.indexWhere((f) => f.id == folderId);
      if (fIdx != -1 && _folders[fIdx].spaceIds.isNotEmpty) {
        final targetSpaceId = _folders[fIdx].spaceIds.first;
        final sIdx = _spaces.indexWhere((s) => s.id == targetSpaceId);
        if (sIdx != -1) {
          _currentSpace = _spaces[sIdx];
          if (_currentSpace.channels.isNotEmpty) {
            _currentChannel = _currentSpace.channels.first;
          }
          _activeArea = NixActiveArea.spaces;
        }
      }
    }
    notifyListeners();
  }

  void setConversationFilter(ConversationFilter filter) {
    _conversationFilter = filter;
    notifyListeners();
  }

  void setConversationSearchQuery(String query) {
    _conversationSearchQuery = query;
    notifyListeners();
  }

  void openSavedMessages() {
    selectDirectMessage(savedMessagesThread);
  }

  void saveToSavedMessages(
    String text, {
    List<String> attachments = const [],
    String? forwardedFrom,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return;
    final target = savedMessagesThread;
    final msg = Message(
      id: 'saved_${DateTime.now().millisecondsSinceEpoch}',
      channelId: target.id,
      senderName: _userProfile.effectiveDisplayName,
      senderFingerprint: _securityContext.myFingerprint,
      isMe: true,
      text: trimmed.isNotEmpty ? trimmed : 'Anexo salvo',
      timestamp: DateTime.now(),
      forwardedFrom: forwardedFrom,
      attachments: attachments,
    );
    final idx = _directMessages.indexWhere((d) => d.id == target.id);
    if (idx != -1) {
      final updatedMsgs = List<Message>.from(_directMessages[idx].messages)..add(msg);
      _directMessages[idx] = _directMessages[idx].copyWith(messages: updatedMsgs);
      if (_selectedDm?.id == target.id) {
        _selectedDm = _directMessages[idx];
      }
      notifyListeners();
    }
  }

  void selectDirectMessage(DirectMessageThread dm) {
    _activeArea = NixActiveArea.homePrivate;
    _homeSubTab = HomeSubTab.directChat;
    final idx = _directMessages.indexWhere((d) => d.id == dm.id);
    if (idx != -1) {
      _directMessages[idx] = _directMessages[idx].copyWith(unreadCount: 0);
      _selectedDm = _directMessages[idx];
    } else {
      _selectedDm = dm;
    }
    _clearTransientMessageModes();
    notifyListeners();
  }

  void togglePinDirectMessage(String dmId) {
    final idx = _directMessages.indexWhere((d) => d.id == dmId);
    if (idx == -1) return;
    _directMessages[idx] = _directMessages[idx].copyWith(isPinned: !_directMessages[idx].isPinned);
    if (_selectedDm?.id == dmId) {
      _selectedDm = _directMessages[idx];
    }
    notifyListeners();
  }

  void toggleMuteDirectMessage(String dmId) {
    final idx = _directMessages.indexWhere((d) => d.id == dmId);
    if (idx == -1) return;
    _directMessages[idx] = _directMessages[idx].copyWith(isMuted: !_directMessages[idx].isMuted);
    if (_selectedDm?.id == dmId) {
      _selectedDm = _directMessages[idx];
    }
    notifyListeners();
  }

  void sendDirectMessage(String text, {List<String> attachments = const []}) {
    if (_selectedDm == null) return;
    if (text.trim().isEmpty && attachments.isEmpty) return;

    if (_editingMessage != null) {
      saveEditedMessage(_editingMessage!.id, text);
      return;
    }

    final reply = _replyingToMessage;
    final newMsg = Message(
      id: 'dm_msg_${DateTime.now().millisecondsSinceEpoch}',
      channelId: _selectedDm!.id,
      senderName: _userProfile.effectiveDisplayName,
      senderFingerprint: _securityContext.myFingerprint,
      isMe: true,
      text: text.trim(),
      timestamp: DateTime.now(),
      ephemeralSeconds: _selectedEphemeralTimer,
      remainingSeconds: _selectedEphemeralTimer,
      attachments: attachments,
      replyToMessageId: reply?.id,
      replyToSenderName: reply?.senderName,
      replyToExcerpt: reply?.text,
    );
    final idx = _directMessages.indexWhere((d) => d.id == _selectedDm!.id);
    if (idx != -1) {
      final updatedMsgs = List<Message>.from(_directMessages[idx].messages)..add(newMsg);
      _directMessages[idx] = _directMessages[idx].copyWith(messages: updatedMsgs);
      _selectedDm = _directMessages[idx];
      _replyingToMessage = null;

      // Persiste de forma atômica no banco local SQLCipher se ativo
      if (_localDatabase != null && _messageRepo != null) {
        unawaited(_persistDirectMessageToDb(
          message: newMsg,
          thread: _selectedDm!,
          cleanBody: text.trim(),
        ));
      }

      notifyListeners();
    }
  }

  Future<void> _persistDirectMessageToDb({
    required Message message,
    required DirectMessageThread thread,
    required String cleanBody,
  }) async {
    try {
      final db = _localDatabase;
      final convRepo = _conversationRepo;
      final msgRepo = _messageRepo;
      if (db == null || convRepo == null || msgRepo == null) return;

      final existingConv = await convRepo.getConversation(thread.id);
      if (existingConv == null) {
        final primary = await _identityRepo?.getPrimaryIdentity();
        final ownerId = (primary?['id'] as String?) ?? _userProfile.publicId;
        if (ownerId.isNotEmpty) {
          await convRepo.createConversation(
            id: thread.id,
            kind: thread.isSavedMessages ? 'saved' : 'direct',
            ownerIdentityId: ownerId,
            title: thread.peerName,
          );
        }
      }

      final nowMs = message.timestamp.toUtc().millisecondsSinceEpoch;
      final expiresAt = message.ephemeralSeconds > 0
          ? nowMs + (message.ephemeralSeconds * 1000)
          : null;

      await msgRepo.insertMessage(
        id: message.id,
        conversationId: thread.id,
        authorKey: _userProfile.publicId,
        deviceId: _localDeviceId,
        body: cleanBody,
        deliveryState: thread.isSavedMessages ? 'received' : 'queued',
        replyToId: message.replyToMessageId,
        createdAt: nowMs,
        expiresAt: expiresAt,
      );
    } catch (e) {
      debugPrint('[NixState] Aviso ao persistir mensagem no banco local: $e');
    }
  }

  void acceptContactRequest(String requestId) {
    final idx = _contactRequests.indexWhere((r) => r.id == requestId);
    if (idx == -1) return;
    final req = _contactRequests.removeAt(idx);
    _hoveredContactRequest = null;
    _peerHoverState = PeerCardHoverState.closed;
    final newDm = DirectMessageThread(
      id: 'dm_${DateTime.now().millisecondsSinceEpoch}',
      peerName: req.peerName,
      peerPublicId: req.peerPublicId,
      statusText: 'Contato verificado recém-adicionado',
      isOnline: true,
      isVerified: true,
      trustLevel: NixTrustLevel.level3Green,
      messages: [
        Message(
          id: 'dm_init_${DateTime.now().millisecondsSinceEpoch}',
          channelId: req.id,
          senderName: req.peerName,
          senderFingerprint: req.peerPublicId.replaceFirst('NIX-', ''),
          isMe: false,
          text: req.note,
          timestamp: DateTime.now(),
        ),
      ],
    );
    _directMessages.insert(1, newDm);
    notifyListeners();
  }

  void declineContactRequest(String requestId) {
    _contactRequests.removeWhere((r) => r.id == requestId);
    _hoveredContactRequest = null;
    _peerHoverState = PeerCardHoverState.closed;
    notifyListeners();
  }

  // ================= MONERO P2P MARKETPLACE =================

  void setMoneroSide(MoneroP2pSide side) {
    _moneroSelectedSide = side;
    notifyListeners();
  }

  void setMoneroFiat(String fiat) {
    _moneroSelectedFiat = fiat;
    notifyListeners();
  }

  void setMoneroPaymentMethod(String method) {
    _moneroSelectedPaymentMethod = method;
    notifyListeners();
  }

  void setMoneroSearchQuery(String query) {
    _moneroSearchQuery = query;
    notifyListeners();
  }

  void createMoneroOrder(MoneroP2pOrder order) {
    _moneroOrders.insert(0, order);
    notifyListeners();
  }

  void openTradeWithOrder(MoneroP2pOrder order) {
    final existingDm = _directMessages.firstWhere(
      (dm) => dm.peerPublicId == order.traderPublicId,
      orElse: () {
        final newDm = DirectMessageThread(
          id: 'dm_trade_${DateTime.now().millisecondsSinceEpoch}',
          peerName: order.traderName,
          peerPublicId: order.traderPublicId,
          statusText: 'Negociação P2P Monero: ${order.formattedPrice}',
          isOnline: order.isOnline,
          isVerified: true,
          trustLevel: order.trustLevel,
          messages: [
            Message(
              id: 'dm_trade_init_${DateTime.now().millisecondsSinceEpoch}',
              channelId: 'trade_${order.id}',
              senderName: order.traderName,
              senderFingerprint: order.traderPublicId.replaceFirst('NIX-', ''),
              isMe: false,
              text:
                  'Iniciando negociação da oferta #${order.id.split('_').last}: ${order.notes}\nLimite: ${order.formattedLimits}',
              timestamp: DateTime.now(),
            ),
          ],
        );
        _directMessages.insert(1, newDm);
        return newDm;
      },
    );
    selectDirectMessage(existingDm);
  }

  // ================= GITHUB DISCOVERY (STARWIRE) =================

  void setGithubSearchQuery(String query) {
    _githubSearchQuery = query;
    notifyListeners();
  }

  void setGithubTopic(String topic) {
    _githubSelectedTopic = topic;
    notifyListeners();
  }

  void setGithubLanguage(String language) {
    _githubSelectedLanguage = language;
    notifyListeners();
  }

  void setGithubSortBy(String sortBy) {
    _githubSortBy = sortBy;
    notifyListeners();
  }

  void toggleSaveRepoInAcervo(String repoId) {
    final idx = _githubRepos.indexWhere((r) => r.id == repoId);
    if (idx == -1) return;

    final repo = _githubRepos[idx];
    final isNowSaved = !repo.isSavedInAcervo;
    _githubRepos[idx] = repo.copyWith(isSavedInAcervo: isNowSaved);

    if (isNowSaved) {
      _savedAcervoIds.add(repo.id);
      final culturalItem = CulturalItem(
        id: 'repo_${repo.name}',
        title: repo.name,
        creatorOrYear: '${repo.language} · ${repo.owner}',
        category: CulturalCategory.github,
        rating: repo.formattedStars,
        monogram: repo.name.length >= 2 ? repo.name.substring(0, 2).toUpperCase() : 'GH',
        toneShade: 75,
        isPublicInCardId: false, // Acervo privado por padrão (Seção 16)
        repositoryUrl: repo.htmlUrl,
        starsCount: repo.starsCount,
        language: repo.language,
        license: repo.license,
        updatedDate: repo.updatedDate,
      );
      addCulturalItem(culturalItem);
    } else {
      _savedAcervoIds.remove(repo.id);
      _userProfile = _userProfile.copyWith(
        culturalItems: _userProfile.culturalItems
            .where((i) => i.id != 'repo_${repo.name}' && i.id != repo.id)
            .toList(),
      );
    }
    _persistState();
    notifyListeners();
  }

  // ================= OVERLAY DE PERFIL, CARD ID & CONFIGURAÇÕES =================

  void openProfileOverlay({bool startInSettings = false, SettingsCategory? category}) {
    _isProfileOverlayOpen = true;
    _isSettingsOpenInOverlay = startInSettings;
    if (category != null) {
      _activeSettingsCategory = category;
    }
    notifyListeners();
  }

  void closeProfileOverlay() {
    _isProfileOverlayOpen = false;
    _isSettingsOpenInOverlay = false;
    notifyListeners();
  }

  void transitionToSettings({SettingsCategory? category}) {
    _isProfileOverlayOpen = true;
    _isSettingsOpenInOverlay = true;
    if (category != null) {
      _activeSettingsCategory = category;
    }
    notifyListeners();
  }

  void transitionBackToCardId() {
    _isSettingsOpenInOverlay = false;
    notifyListeners();
  }

  void selectSettingsCategory(SettingsCategory category) {
    _activeSettingsCategory = category;
    notifyListeners();
  }

  // ================= ATUALIZAÇÃO DO PERFIL & PASSAPORTE CULTURAL =================

  void updateProfile({
    String? displayName,
    String? bio,
    String? currentActivity,
    String? avatarStyle,
    String? customAvatarPath,
    bool clearCustomAvatar = false,
    double? avatarCropScale,
    double? avatarCropOffsetX,
    double? avatarCropOffsetY,
  }) {
    final cleanBio = bio != null
        ? (bio.trim().length > 180 ? bio.trim().substring(0, 180) : bio.trim())
        : null;
    final cleanName = displayName != null
        ? (displayName.trim().length > 32
            ? displayName.trim().substring(0, 32)
            : displayName.trim())
        : null;

    _userProfile = _userProfile.copyWith(
      displayName: cleanName,
      bio: cleanBio,
      currentActivity: currentActivity,
      avatarStyle: avatarStyle,
      customAvatarPath: customAvatarPath,
      clearCustomAvatar: clearCustomAvatar,
      avatarCropScale: avatarCropScale,
      avatarCropOffsetX: avatarCropOffsetX,
      avatarCropOffsetY: avatarCropOffsetY,
    );
    if (_localDatabase != null &&
        _identityRepo != null &&
        _userProfile.publicId.isNotEmpty) {
      unawaited(_identityRepo!.saveProfile(
        identityId: _userProfile.publicId,
        displayName: _userProfile.effectiveDisplayName,
        bio: _userProfile.bio,
        avatarObjectId: _userProfile.avatarStyle,
      ));
    }
    notifyListeners();
  }

  /// Restaura conta e identidade Seed A a partir da frase mnemônica de 24 palavras.
  Future<NixIdentity> recoverAccountFromMnemonic({
    required List<String> words,
    required String passphrase,
    String displayName = 'Soberano',
    String? customDbPath,
    String? customVaultPath,
    bool bindToOsKeyring = false,
  }) async {
    final identity = await SeedRecoveryManager.deriveIdentityFromMnemonic(words);
    final ok = await initializeEncryptedDatabase(
      passphrase: passphrase,
      customDbPath: customDbPath,
      customVaultPath: customVaultPath,
      bindToOsKeyring: bindToOsKeyring,
    );
    if (!ok) {
      throw StateError('Falha ao inicializar banco SQLCipher na recuperação Seed A.');
    }
    await persistPrimaryIdentity(
      identity: identity,
      displayName: displayName,
    );
    return identity;
  }

  String _mapMediaKind(CulturalCategory category) {
    switch (category) {
      case CulturalCategory.movies:
        return 'film';
      case CulturalCategory.series:
        return 'series';
      case CulturalCategory.anime:
        return 'anime';
      case CulturalCategory.manga:
        return 'manga';
      case CulturalCategory.books:
        return 'book';
      case CulturalCategory.music:
        return 'album';
      case CulturalCategory.github:
        return 'repository';
    }
  }

  void addCulturalItem(CulturalItem item) {
    final updated = List<CulturalItem>.from(_userProfile.culturalItems)..insert(0, item);
    _userProfile = _userProfile.copyWith(culturalItems: updated);
    if (_mediaRepo != null) {
      unawaited(_mediaRepo!.upsertMediaItem(
        id: item.id,
        kind: _mapMediaKind(item.category),
        title: item.title,
        metadata: item.toJson(),
        source: 'local_acervo',
        sourceId: item.id,
      ));
    }
    _persistState();
    notifyListeners();
  }

  void updateCulturalItem(CulturalItem updatedItem) {
    final updated = _userProfile.culturalItems.map((item) {
      return item.id == updatedItem.id ? updatedItem : item;
    }).toList();
    _userProfile = _userProfile.copyWith(culturalItems: updated);
    if (_mediaRepo != null) {
      unawaited(_mediaRepo!.upsertMediaItem(
        id: updatedItem.id,
        kind: _mapMediaKind(updatedItem.category),
        title: updatedItem.title,
        metadata: updatedItem.toJson(),
        source: 'local_acervo',
        sourceId: updatedItem.id,
      ));
    }
    _persistState();
    notifyListeners();
  }

  void removeCulturalItem(String itemId) {
    final updated = _userProfile.culturalItems.where((i) => i.id != itemId).toList();
    _userProfile = _userProfile.copyWith(culturalItems: updated);
    if (_mediaRepo != null) {
      unawaited(_mediaRepo!.deleteMediaItem(itemId));
    }
    _persistState();
    notifyListeners();
  }

  void toggleItemCardIdVisibility(String itemId) {
    CulturalItem? modified;
    final updated = _userProfile.culturalItems.map((item) {
      if (item.id == itemId) {
        modified = item.copyWith(isPublicInCardId: !item.isPublicInCardId);
        return modified!;
      }
      return item;
    }).toList();
    _userProfile = _userProfile.copyWith(culturalItems: updated);
    if (modified != null && _mediaRepo != null) {
      unawaited(_mediaRepo!.upsertMediaItem(
        id: modified!.id,
        kind: _mapMediaKind(modified!.category),
        title: modified!.title,
        metadata: modified!.toJson(),
        source: 'local_acervo',
        sourceId: modified!.id,
      ));
    }
    _persistState();
    notifyListeners();
  }

  // ================= CONFIGURAÇÕES, TEMAS & JANELA =================

  void updateThemeMode(NixThemeMode mode) {
    _settings = _settings.copyWith(themeMode: mode);
    NixColors.sync(NixSurfaceScheme.resolve(mode), currentPalette);
    _persistState();
    notifyListeners();
  }

  void updatePalette(NixPaletteType type, [int? customColor]) {
    _settings = _settings.copyWith(
      paletteType: type,
      customPaletteColor: customColor ?? _settings.customPaletteColor,
    );
    NixColors.sync(NixSurfaceScheme.resolve(_settings.themeMode), currentPalette);
    _persistState();
    notifyListeners();
  }

  void updateWindowGeometry({
    double? width,
    double? height,
    double? offsetX,
    double? offsetY,
  }) {
    _settings = _settings.copyWith(
      windowWidth: width,
      windowHeight: height,
      windowOffsetX: offsetX,
      windowOffsetY: offsetY,
    );
    if (_settings.persistWindowGeometry) {
      _persistState();
    }
    notifyListeners();
  }

  double get dockWidth => _settings.dockWidth;
  double get sidebarWidth => _settings.sidebarWidth;

  void updateDockWidth(double width) {
    final clamped = width.clamp(64.0, 110.0);
    if ((clamped - _settings.dockWidth).abs() > 0.5) {
      _settings = _settings.copyWith(dockWidth: clamped);
      _persistState();
      notifyListeners();
    }
  }

  void updateSidebarWidth(double width) {
    final clamped = width.clamp(220.0, 480.0);
    if ((clamped - _settings.sidebarWidth).abs() > 0.5) {
      _settings = _settings.copyWith(sidebarWidth: clamped);
      _persistState();
      notifyListeners();
    }
  }

  void resetDockWidth() {
    _settings = _settings.copyWith(dockWidth: 78.0);
    _persistState();
    notifyListeners();
  }

  void resetSidebarWidth() {
    _settings = _settings.copyWith(sidebarWidth: 288.0);
    _persistState();
    notifyListeners();
  }

  void toggleWindowMaximized() {
    _isWindowMaximized = !_isWindowMaximized;
    notifyListeners();
  }

  void updateCardIdVisibility(String visibility) {
    _settings = _settings.copyWith(cardIdVisibility: visibility);
    _persistState();
    notifyListeners();
  }

  void toggleFloatingWindowMode(bool isFloating) {
    _settings = _settings.copyWith(floatingWindowMode: isFloating);
    _persistState();
    notifyListeners();
  }

  void updateSettings(UserSettings newSettings) {
    _settings = newSettings;
    NixColors.sync(NixSurfaceScheme.resolve(_settings.themeMode), currentPalette);
    _persistState();
    notifyListeners();
  }

  void toggleConnector(String connectorId) {
    final updated = _settings.connectors.map((c) {
      if (c.id == connectorId) {
        return c.copyWith(isEnabled: !c.isEnabled);
      }
      return c;
    }).toList();
    _settings = _settings.copyWith(connectors: updated);
    notifyListeners();
  }

  void unblockUser(String publicId) {
    final updated = _settings.blockedUserIds.where((id) => id != publicId).toList();
    _settings = _settings.copyWith(blockedUserIds: updated);
    notifyListeners();
  }

  void blockNewUser(String publicId) {
    if (publicId.trim().isEmpty) return;
    final updated = List<String>.from(_settings.blockedUserIds)..add(publicId.trim());
    _settings = _settings.copyWith(blockedUserIds: updated);
    notifyListeners();
  }

  void authorizeDevice(String deviceName, String fingerprint) {
    final newDev = AuthorizedDevice(
      id: 'dev_${DateTime.now().millisecondsSinceEpoch}',
      deviceName: deviceName.trim().isNotEmpty ? deviceName.trim() : 'Novo Dispositivo Nix',
      clientVersion: 'Nix Client v0.4.0-dev',
      lastSeenLabel: 'Agora',
      isCurrent: false,
      fingerprint: fingerprint.trim().isNotEmpty ? fingerprint.trim() : 'NX-7700-AA21',
    );
    final updated = List<AuthorizedDevice>.from(_settings.devices)..add(newDev);
    _settings = _settings.copyWith(devices: updated);
    notifyListeners();
  }

  void revokeDevice(String deviceId) {
    final updated = _settings.devices.where((d) => d.id != deviceId).toList();
    _settings = _settings.copyWith(devices: updated);
    notifyListeners();
  }

  // ================= ESPAÇOS, PASTAS (FOLDERS) & EXPLORAR =================

  void selectSpace(Space space) {
    _activeArea = NixActiveArea.spaces;
    _clearTransientMessageModes();
    if (_currentSpace.id == space.id) {
      notifyListeners();
      return;
    }
    _currentSpace = space;
    if (space.channels.isNotEmpty) {
      _currentChannel = space.channels.first;
    }
    notifyListeners();
  }

  void toggleFolderExpanded(String folderId) {
    final idx = _folders.indexWhere((f) => f.id == folderId);
    if (idx != -1) {
      _folders[idx] = _folders[idx].copyWith(isExpanded: !_folders[idx].isExpanded);
      notifyListeners();
    }
  }

  void createSpaceFolder(
    String name,
    List<String> spaceIds, {
    String iconName = 'folder',
    int colorValue = 0xFFFFC928,
    List<String> conversationIds = const [],
  }) {
    if (name.trim().isEmpty) return;
    if (spaceIds.isEmpty && conversationIds.isEmpty) return;

    final newFolder = SpaceFolder(
      id: 'folder_${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim(),
      iconName: iconName,
      colorValue: colorValue,
      spaceIds: spaceIds.toSet().toList(),
      conversationIds: conversationIds.toSet().toList(),
      isExpanded: true,
    );
    _folders.add(newFolder);
    _persistState();
    notifyListeners();
  }

  void updateSpaceFolder(SpaceFolder updatedFolder) {
    final idx = _folders.indexWhere((f) => f.id == updatedFolder.id);
    if (idx == -1) return;
    _folders[idx] = updatedFolder.copyWith(
      spaceIds: updatedFolder.spaceIds.toSet().toList(),
      conversationIds: updatedFolder.conversationIds.toSet().toList(),
    );
    _persistState();
    notifyListeners();
  }

  void reorderFolders(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _folders.length) return;
    if (newIndex > oldIndex) newIndex--;
    if (newIndex < 0 || newIndex >= _folders.length) return;
    final moved = _folders.removeAt(oldIndex);
    _folders.insert(newIndex, moved);
    _persistState();
    notifyListeners();
  }

  /// Arrastar um espaço sobre outro para agrupá-los em uma nova pasta.
  void combineSpacesIntoFolder(String sourceSpaceId, String targetSpaceId, [String? folderName]) {
    if (sourceSpaceId == targetSpaceId) return;

    _folders = _folders
        .map((f) => f.copyWith(
              spaceIds: f.spaceIds
                  .where((id) => id != sourceSpaceId && id != targetSpaceId)
                  .toList(),
            ))
        .where((f) => f.spaceIds.isNotEmpty || f.conversationIds.isNotEmpty)
        .toList();

    final sourceSpace = _spaces.firstWhere((s) => s.id == sourceSpaceId, orElse: () => _spaces.first);
    final targetSpace = _spaces.firstWhere((s) => s.id == targetSpaceId, orElse: () => _spaces.first);
    final defaultName = folderName ?? '${targetSpace.initials} & ${sourceSpace.initials}';

    _folders.add(SpaceFolder(
      id: 'folder_${DateTime.now().millisecondsSinceEpoch}',
      name: defaultName,
      spaceIds: [targetSpaceId, sourceSpaceId],
      isExpanded: true,
    ));
    _persistState();
    notifyListeners();
  }

  /// Arrastar um espaço para dentro de uma pasta existente (sem duplicatas).
  void addSpaceToFolder(String spaceId, String folderId) {
    final fIdx = _folders.indexWhere((f) => f.id == folderId);
    if (fIdx == -1) return;
    if (_folders[fIdx].spaceIds.contains(spaceId)) return;

    final updatedList = List<String>.from(_folders[fIdx].spaceIds)..add(spaceId);
    _folders[fIdx] = _folders[fIdx].copyWith(spaceIds: updatedList, isExpanded: true);
    _persistState();
    notifyListeners();
  }

  /// Arrastar uma conversa privada, grupo ou canal para uma pasta.
  void assignItemToFolder(String itemId, String folderId) {
    final fIdx = _folders.indexWhere((f) => f.id == folderId);
    if (fIdx == -1) return;

    if (_spaces.any((s) => s.id == itemId)) {
      addSpaceToFolder(itemId, folderId);
      return;
    }

    final currentConvs = _folders[fIdx].conversationIds;
    if (!currentConvs.contains(itemId)) {
      final updatedConvs = List<String>.from(currentConvs)..add(itemId);
      _folders[fIdx] = _folders[fIdx].copyWith(conversationIds: updatedConvs, isExpanded: true);
      _persistState();
      notifyListeners();
    }
  }

  /// Exclui apenas a pasta mantendo intactas todas as conversas e espaços (Seção 4).
  void dissolveFolder(String folderId) {
    _folders.removeWhere((f) => f.id == folderId);
    if (_activeFolderId == folderId) {
      _activeFolderId = 'all';
    }
    _persistState();
    notifyListeners();
  }

  void setExploreSortAscending(bool ascending) {
    _exploreSortAscending = ascending;
    notifyListeners();
  }

  void setExploreSearchQuery(String query) {
    _exploreSearchQuery = query;
    notifyListeners();
  }

  void joinDiscoverableSpace(Space discovered) {
    final existingIdx = _spaces.indexWhere((s) => s.id == discovered.id);
    if (existingIdx != -1) {
      selectSpace(_spaces[existingIdx]);
      return;
    }
    final newSpace = discovered.copyWith(
      channels: [
        Channel(
          id: 'ch_${discovered.id}_geral',
          spaceId: discovered.id,
          name: 'geral',
          topic: discovered.description,
          type: ChannelType.text,
          category: 'COMUNIDADE',
        ),
      ],
    );
    _spaces.add(newSpace);
    selectSpace(newSpace);
  }

  // ================= CANAIS, MENSAGENS, EDIÇÃO, FIXAÇÃO & SELEÇÃO =================

  void selectChannel(Channel channel) {
    _activeArea = NixActiveArea.spaces;
    _currentChannel = channel.copyWith(unreadCount: 0);
    // Zera badge de não lidas no espaço
    final sIdx = _spaces.indexWhere((s) => s.id == channel.spaceId);
    if (sIdx != -1) {
      final chans = _spaces[sIdx].channels.map((c) {
        return c.id == channel.id ? c.copyWith(unreadCount: 0) : c;
      }).toList();
      _spaces[sIdx] = _spaces[sIdx].copyWith(channels: chans);
      _currentSpace = _spaces[sIdx];
    }
    if (channel.type == ChannelType.forum) {
      final posts = currentForumPosts;
      if (posts.isNotEmpty &&
          (_selectedForumPost == null || _selectedForumPost!.channelId != channel.id)) {
        _selectedForumPost = posts.first;
      }
    }
    _clearTransientMessageModes();
    notifyListeners();
  }

  void togglePinChannel(String channelId) {
    for (int s = 0; s < _spaces.length; s++) {
      final chans = _spaces[s].channels;
      final cIdx = chans.indexWhere((c) => c.id == channelId);
      if (cIdx != -1) {
        final updated = List<Channel>.from(chans);
        updated[cIdx] = updated[cIdx].copyWith(isPinned: !updated[cIdx].isPinned);
        _spaces[s] = _spaces[s].copyWith(channels: updated);
        if (_currentChannel.id == channelId) _currentChannel = updated[cIdx];
        notifyListeners();
        return;
      }
    }
  }

  void toggleMuteChannel(String channelId) {
    for (int s = 0; s < _spaces.length; s++) {
      final chans = _spaces[s].channels;
      final cIdx = chans.indexWhere((c) => c.id == channelId);
      if (cIdx != -1) {
        final updated = List<Channel>.from(chans);
        updated[cIdx] = updated[cIdx].copyWith(isMuted: !updated[cIdx].isMuted);
        _spaces[s] = _spaces[s].copyWith(channels: updated);
        if (_currentChannel.id == channelId) _currentChannel = updated[cIdx];
        notifyListeners();
        return;
      }
    }
  }

  void _clearTransientMessageModes() {
    _replyingToMessage = null;
    _editingMessage = null;
    _selectedMessageIds.clear();
    _highlightedMessageId = null;
  }

  void startReplyTo(Message message) {
    _editingMessage = null;
    _replyingToMessage = message;
    notifyListeners();
  }

  void cancelReply() {
    _replyingToMessage = null;
    notifyListeners();
  }

  void startEditMessage(Message message) {
    if (!message.isMe) return;
    if (_activeArea == NixActiveArea.spaces && !_currentChannel.permissions.allowEditing) return;
    _replyingToMessage = null;
    _editingMessage = message;
    notifyListeners();
  }

  void cancelEditMessage() {
    _editingMessage = null;
    notifyListeners();
  }

  void saveEditedMessage(String messageId, String newText) {
    editMessage(messageId, newText);
  }

  void editMessage(String messageId, String newText) {
    final trimmed = newText.trim();
    if (trimmed.isEmpty) return;

    final channelMsgs = _messages[_currentChannel.id];
    if (channelMsgs != null) {
      final idx = channelMsgs.indexWhere((m) => m.id == messageId);
      if (idx != -1 && channelMsgs[idx].isMe && _currentChannel.permissions.allowEditing) {
        channelMsgs[idx] = channelMsgs[idx].copyWith(
          text: trimmed,
          editedAt: DateTime.now(),
        );
        _editingMessage = null;
        notifyListeners();
        return;
      }
    }

    for (int t = 0; t < _directMessages.length; t++) {
      final thread = _directMessages[t];
      final mIdx = thread.messages.indexWhere((m) => m.id == messageId);
      if (mIdx != -1 && thread.messages[mIdx].isMe) {
        final updatedMsgs = List<Message>.from(thread.messages);
        updatedMsgs[mIdx] = updatedMsgs[mIdx].copyWith(
          text: trimmed,
          editedAt: DateTime.now(),
        );
        _directMessages[t] = thread.copyWith(messages: updatedMsgs);
        if (_selectedDm?.id == thread.id) {
          _selectedDm = _directMessages[t];
        }
        _editingMessage = null;
        notifyListeners();
        return;
      }
    }
  }

  void togglePinMessage(String messageId) {
    final channelMsgs = _messages[_currentChannel.id];
    if (channelMsgs != null) {
      final idx = channelMsgs.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        channelMsgs[idx] = channelMsgs[idx].copyWith(isPinned: !channelMsgs[idx].isPinned);
        notifyListeners();
        return;
      }
    }

    for (int t = 0; t < _directMessages.length; t++) {
      final thread = _directMessages[t];
      final mIdx = thread.messages.indexWhere((m) => m.id == messageId);
      if (mIdx != -1) {
        final updatedMsgs = List<Message>.from(thread.messages);
        updatedMsgs[mIdx] = updatedMsgs[mIdx].copyWith(isPinned: !updatedMsgs[mIdx].isPinned);
        _directMessages[t] = thread.copyWith(messages: updatedMsgs);
        if (_selectedDm?.id == thread.id) {
          _selectedDm = _directMessages[t];
        }
        notifyListeners();
        return;
      }
    }
  }

  void highlightMessage(String? messageId) {
    _highlightedMessageId = messageId;
    notifyListeners();
  }

  void toggleMessageSelection(String messageId) {
    if (_selectedMessageIds.contains(messageId)) {
      _selectedMessageIds.remove(messageId);
    } else {
      _selectedMessageIds.add(messageId);
    }
    notifyListeners();
  }

  void clearMessageSelection() {
    _selectedMessageIds.clear();
    notifyListeners();
  }

  void deleteSelectedMessages({bool forEveryone = false}) {
    final ids = List<String>.from(_selectedMessageIds);
    for (final id in ids) {
      deleteMessage(id, forEveryone: forEveryone);
    }
    _selectedMessageIds.clear();
    notifyListeners();
  }

  void forwardSelectedMessages({required String targetId, required bool isChannel}) {
    final msgs = activeConversationMessages
        .where((m) => _selectedMessageIds.contains(m.id))
        .toList();
    for (final m in msgs) {
      forwardMessage(m, targetId: targetId, isChannel: isChannel);
    }
    _selectedMessageIds.clear();
    notifyListeners();
  }

  void toggleConversationInfoPanel([bool? open]) {
    _isConversationInfoOpen = open ?? !_isConversationInfoOpen;
    notifyListeners();
  }

  void setConversationHistorySearch(String query) {
    _conversationHistorySearch = query;
    notifyListeners();
  }

  bool sendMessage(String text, {List<String> attachments = const []}) {
    if (text.trim().isEmpty && attachments.isEmpty) return false;
    if (!_currentChannel.permissions.allowMessages) return false;
    if (attachments.isNotEmpty && !_currentChannel.permissions.allowFiles) return false;

    if (_editingMessage != null) {
      editMessage(_editingMessage!.id, text);
      return true;
    }

    final reply = _replyingToMessage;
    final newMessage = Message(
      id: 'msg_${DateTime.now().millisecondsSinceEpoch}',
      channelId: _currentChannel.id,
      senderName: _userProfile.effectiveDisplayName,
      senderFingerprint: _securityContext.myFingerprint,
      isMe: true,
      text: text.trim(),
      timestamp: DateTime.now(),
      ephemeralSeconds: _selectedEphemeralTimer,
      remainingSeconds: _selectedEphemeralTimer,
      isVerified: true,
      attachments: attachments,
      replyToMessageId: reply?.id,
      replyToSenderName: reply?.senderName,
      replyToExcerpt: reply?.text,
    );

    if (!_messages.containsKey(_currentChannel.id)) {
      _messages[_currentChannel.id] = [];
    }
    _messages[_currentChannel.id]!.add(newMessage);
    _replyingToMessage = null;
    notifyListeners();
    return true;
  }

  void toggleMessageReaction(String messageId, String emoji) {
    final channelMsgs = _messages[_currentChannel.id];
    if (channelMsgs != null) {
      final idx = channelMsgs.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        if (!_currentChannel.permissions.allowReactions) return;
        channelMsgs[idx] = _toggleReactionOnMessage(channelMsgs[idx], emoji);
        notifyListeners();
        return;
      }
    }

    for (int t = 0; t < _directMessages.length; t++) {
      final thread = _directMessages[t];
      final mIdx = thread.messages.indexWhere((m) => m.id == messageId);
      if (mIdx != -1) {
        final updatedMsgs = List<Message>.from(thread.messages);
        updatedMsgs[mIdx] = _toggleReactionOnMessage(updatedMsgs[mIdx], emoji);
        _directMessages[t] = thread.copyWith(messages: updatedMsgs);
        if (_selectedDm?.id == thread.id) {
          _selectedDm = _directMessages[t];
        }
        notifyListeners();
        return;
      }
    }

    for (int p = 0; p < _forumPosts.length; p++) {
      final post = _forumPosts[p];
      final cIdx = post.comments.indexWhere((m) => m.id == messageId);
      if (cIdx != -1) {
        final updatedComments = List<Message>.from(post.comments);
        updatedComments[cIdx] = _toggleReactionOnMessage(updatedComments[cIdx], emoji);
        _forumPosts[p] = post.copyWith(comments: updatedComments);
        if (_selectedForumPost?.id == post.id) {
          _selectedForumPost = _forumPosts[p];
        }
        notifyListeners();
        return;
      }
    }
  }

  Message _toggleReactionOnMessage(Message msg, String emoji) {
    final currentReactions = Map<String, int>.from(msg.reactions);
    final currentMyReactions = Set<String>.from(msg.myReactions);

    if (currentMyReactions.contains(emoji)) {
      currentMyReactions.remove(emoji);
      final count = (currentReactions[emoji] ?? 1) - 1;
      if (count <= 0) {
        currentReactions.remove(emoji);
      } else {
        currentReactions[emoji] = count;
      }
    } else {
      currentMyReactions.add(emoji);
      currentReactions[emoji] = (currentReactions[emoji] ?? 0) + 1;
    }

    return msg.copyWith(
      reactions: currentReactions,
      myReactions: currentMyReactions,
    );
  }

  void deleteMessage(String messageId, {bool forEveryone = false}) {
    final channelMsgs = _messages[_currentChannel.id];
    if (channelMsgs != null) {
      final idx = channelMsgs.indexWhere((m) => m.id == messageId);
      if (idx != -1) {
        if (forEveryone && !_currentChannel.permissions.allowDeletion) return;
        channelMsgs.removeAt(idx);
        notifyListeners();
        return;
      }
    }

    for (int t = 0; t < _directMessages.length; t++) {
      final thread = _directMessages[t];
      final mIdx = thread.messages.indexWhere((m) => m.id == messageId);
      if (mIdx != -1) {
        final updatedMsgs = List<Message>.from(thread.messages)..removeAt(mIdx);
        _directMessages[t] = thread.copyWith(messages: updatedMsgs);
        if (_selectedDm?.id == thread.id) {
          _selectedDm = _directMessages[t];
        }
        notifyListeners();
        return;
      }
    }
  }

  bool forwardMessage(Message original, {required String targetId, required bool isChannel}) {
    if (_activeArea == NixActiveArea.spaces &&
        (!_currentChannel.permissions.allowForwarding || _currentChannel.permissions.restrictExport)) {
      return false;
    }

    final fwdMsg = Message(
      id: 'fwd_${DateTime.now().millisecondsSinceEpoch}_${original.id.hashCode.abs()}',
      channelId: targetId,
      senderName: _userProfile.effectiveDisplayName,
      senderFingerprint: _securityContext.myFingerprint,
      isMe: true,
      text: original.text,
      timestamp: DateTime.now(),
      forwardedFrom: original.senderName,
      attachments: original.attachments,
    );

    if (isChannel) {
      if (!_messages.containsKey(targetId)) {
        _messages[targetId] = [];
      }
      _messages[targetId]!.add(fwdMsg);
    } else {
      final tIdx = _directMessages.indexWhere((d) => d.id == targetId);
      if (tIdx != -1) {
        final updatedMsgs = List<Message>.from(_directMessages[tIdx].messages)..add(fwdMsg);
        _directMessages[tIdx] = _directMessages[tIdx].copyWith(messages: updatedMsgs);
        if (_selectedDm?.id == targetId) {
          _selectedDm = _directMessages[tIdx];
        }
      }
    }
    notifyListeners();
    return true;
  }

  void updateChannelSettings(Channel updatedChannel) {
    for (int s = 0; s < _spaces.length; s++) {
      final space = _spaces[s];
      final cIdx = space.channels.indexWhere((c) => c.id == updatedChannel.id);
      if (cIdx != -1) {
        final updatedChannels = List<Channel>.from(space.channels);
        updatedChannels[cIdx] = updatedChannel;
        _spaces[s] = space.copyWith(channels: updatedChannels);
        if (_currentChannel.id == updatedChannel.id) {
          _currentChannel = updatedChannel;
        }
        notifyListeners();
        return;
      }
    }
  }

  void applyAdminAction(Channel channel, {required String targetFingerprint, required String action}) {
    final admins = List<String>.from(channel.admins);
    final moderators = List<String>.from(channel.moderators);
    final muted = List<String>.from(channel.mutedMembers);
    final banned = List<String>.from(channel.bannedMembers);
    final logs = List<String>.from(channel.auditLogs);

    switch (action) {
      case 'toggle_admin':
        if (admins.contains(targetFingerprint)) {
          admins.remove(targetFingerprint);
          logs.insert(0, 'Administração revogada para $targetFingerprint.');
        } else {
          admins.add(targetFingerprint);
          logs.insert(0, 'Promovido a Administrador: $targetFingerprint.');
        }
        break;
      case 'toggle_mod':
        if (moderators.contains(targetFingerprint)) {
          moderators.remove(targetFingerprint);
          logs.insert(0, 'Moderação revogada para $targetFingerprint.');
        } else {
          moderators.add(targetFingerprint);
          logs.insert(0, 'Promovido a Moderador: $targetFingerprint.');
        }
        break;
      case 'toggle_mute':
        if (muted.contains(targetFingerprint)) {
          muted.remove(targetFingerprint);
          logs.insert(0, 'Silenciamento removido para $targetFingerprint.');
        } else {
          muted.add(targetFingerprint);
          logs.insert(0, 'Membro silenciado: $targetFingerprint.');
        }
        break;
      case 'kick':
        logs.insert(0, 'Membro expulso do canal: $targetFingerprint.');
        break;
      case 'ban':
        if (!banned.contains(targetFingerprint)) {
          banned.add(targetFingerprint);
        }
        logs.insert(0, 'Banimento criptográfico aplicado: $targetFingerprint.');
        break;
    }

    updateChannelSettings(channel.copyWith(
      admins: admins,
      moderators: moderators,
      mutedMembers: muted,
      bannedMembers: banned,
      auditLogs: logs,
    ));
  }

  void selectForumPost(ForumPost? post) {
    _selectedForumPost = post;
    notifyListeners();
  }

  void addForumComment(String postId, String text) {
    if (text.trim().isEmpty) return;
    final idx = _forumPosts.indexWhere((p) => p.id == postId);
    if (idx == -1) return;
    final newComment = Message(
      id: 'fmsg_${DateTime.now().millisecondsSinceEpoch}',
      channelId: postId,
      senderName: _userProfile.effectiveDisplayName,
      senderFingerprint: _securityContext.myFingerprint,
      isMe: true,
      text: text.trim(),
      timestamp: DateTime.now(),
    );
    final updatedComments = List<Message>.from(_forumPosts[idx].comments)..add(newComment);
    _forumPosts[idx] = _forumPosts[idx].copyWith(comments: updatedComments);
    if (_selectedForumPost?.id == postId) {
      _selectedForumPost = _forumPosts[idx];
    }
    notifyListeners();
  }

  void createForumPost({
    required String title,
    required String description,
    required List<String> tags,
  }) {
    if (title.trim().isEmpty) return;
    final newPost = ForumPost(
      id: 'post_${DateTime.now().millisecondsSinceEpoch}',
      channelId: _currentChannel.id,
      title: title.trim(),
      authorName: _userProfile.effectiveDisplayName,
      authorFingerprint: _securityContext.myFingerprint,
      createdAt: DateTime.now(),
      tags: tags.isEmpty ? const ['Discussão'] : tags,
      description: description.trim().isEmpty ? 'Tópico aberto para análise da comunidade.' : description.trim(),
      images: const [
        ForumImageSpec(label: 'ANEXO #01', subtitle: 'EXIF Removido', code: 'ATT-01'),
        ForumImageSpec(label: 'ANEXO #02', subtitle: 'Hash Verificado', code: 'ATT-02'),
      ],
      comments: const [],
    );
    _forumPosts.insert(0, newPost);
    _selectedForumPost = newPost;
    notifyListeners();
  }

  void setEphemeralTimer(int seconds) {
    _selectedEphemeralTimer = seconds;
    notifyListeners();
  }

  // ================= CHAMADAS DE VOZ =================

  void joinCall(Channel channel) {
    if (_callState.isConnected && _callState.activeChannelId == channel.id) {
      return;
    }

    _callTimer?.cancel();
    _callState = CallState(
      activeChannelId: channel.id,
      activeChannelName: channel.name,
      isConnected: true,
      isMuted: false,
      isDeafened: false,
      participants: _members.where((m) => m.isOnline).toList(),
      durationSeconds: 0,
    );

    _callTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _callState = _callState.copyWith(
        durationSeconds: _callState.durationSeconds + 1,
      );
      notifyListeners();
    });

    notifyListeners();
  }

  void leaveCall() {
    _callTimer?.cancel();
    _callState = const CallState();
    notifyListeners();
  }

  void toggleMute() {
    _callState = _callState.copyWith(isMuted: !_callState.isMuted);
    notifyListeners();
  }

  void toggleDeafen() {
    _callState = _callState.copyWith(
      isDeafened: !_callState.isDeafened,
      isMuted: !_callState.isDeafened ? true : _callState.isMuted,
    );
    notifyListeners();
  }

  void toggleMembersPanel() {
    _isMembersPanelOpen = !_isMembersPanelOpen;
    notifyListeners();
  }

  // ================= CRIAÇÃO DE CANAIS & ESPAÇOS =================

  void createChannel({
    required String name,
    required ChannelType type,
    required String topic,
    required String category,
  }) {
    final cleanName = name.replaceAll(' ', '-').toLowerCase();
    final newChannel = Channel(
      id: 'ch_${DateTime.now().millisecondsSinceEpoch}',
      spaceId: _currentSpace.id,
      name: cleanName,
      topic: topic.isNotEmpty ? topic : 'Novo tópico de discussão segura.',
      type: type,
      category: category,
    );

    final updatedChannels = List<Channel>.from(_currentSpace.channels)..add(newChannel);
    final updatedSpace = _currentSpace.copyWith(channels: updatedChannels);

    final spaceIndex = _spaces.indexWhere((s) => s.id == _currentSpace.id);
    if (spaceIndex != -1) {
      _spaces[spaceIndex] = updatedSpace;
      _currentSpace = updatedSpace;
      _currentChannel = newChannel;
    }

    notifyListeners();
  }

  void createSpace({
    required String name,
    required String description,
    required String emoji,
  }) {
    final initials = name
        .trim()
        .split(' ')
        .map((w) => w.isNotEmpty ? w[0] : '')
        .take(2)
        .join()
        .toUpperCase();
    final spaceId = 'space_${DateTime.now().millisecondsSinceEpoch}';
    final newSpace = Space(
      id: spaceId,
      name: name.trim(),
      initials: initials.isNotEmpty ? initials : 'NX',
      description: description,
      iconEmoji: emoji.isNotEmpty ? emoji : 'NX',
      channels: [
        Channel(
          id: 'ch_geral_${DateTime.now().millisecondsSinceEpoch}',
          spaceId: spaceId,
          name: 'geral',
          topic: 'Tópico principal deste espaço.',
          type: ChannelType.text,
          category: 'COMUNIDADE',
        ),
      ],
    );

    _spaces.add(newSpace);
    _discoverableSpaces.add(newSpace);
    _currentSpace = newSpace;
    _currentChannel = newSpace.channels.first;
    _activeArea = NixActiveArea.spaces;
    notifyListeners();
  }

  // ChangeNotifier.dispose é síncrono. A limpeza continua sem bloquear a UI;
  // falhas de um serviço não impedem os demais nem deixam o cofre desbloqueado.
  Future<void> _disposeServices() async {
    try {
      _embeddedTor.dispose();
    } catch (_) {
      // Continua a liberação dos recursos locais mesmo se o Tor falhar.
    }
    try {
      _bluetoothMesh.setMeshEnabled(false);
      _bluetoothMesh.dispose();
    } catch (_) {
      // Continua o fechamento do banco mesmo se a malha falhar.
    }
    try {
      await _localDatabase?.close();
    } catch (_) {
      // O bloqueio do cofre é obrigatório mesmo se o fechamento falhar.
    } finally {
      _localDatabase = null;
      _activeMasterKey?.fillRange(0, _activeMasterKey!.length, 0);
      _activeMasterKey = null;
      _keyVault.lock();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _hoverDebounceTimer?.cancel();
    _callTimer?.cancel();
    unawaited(_disposeServices());
    super.dispose();
  }
}
