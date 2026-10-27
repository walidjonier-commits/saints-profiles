import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

const firebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyCH1fe4r5CRJqh-01SI6f_oKMqjv30WokE',
  authDomain: 'jonier-101b4.firebaseapp.com',
  projectId: 'jonier-101b4',
  storageBucket: 'jonier-101b4.firebasestorage.app',
  messagingSenderId: '820455654193',
  appId: '1:820455654193:web:2f49a2c54cba0d3735e610',
);
  
  const fbBlue = Color(0xFF1877F2);
const pageBg = Color(0xFFF0F2F5);
const chipGrey = Color(0xFFE4E6EB);
const emojis = {
  'Like': '👍',
  'Love': '❤️',
  'Care': '🥰',
  'Haha': '😆',
  'Wow': '😮',
  'Sad': '😢',
  'Angry': '😡',
};

// ───────────────────────── helpers ─────────────────────────

FirebaseFirestore get db => FirebaseFirestore.instance;
CollectionReference<Map<String, dynamic>> get profilesCol =>
    db.collection('profiles');

int nowMs() => DateTime.now().millisecondsSinceEpoch;

TextDirection dirOf(String s) =>
    RegExp(r'[\u0600-\u06FF]').hasMatch(s) ? TextDirection.rtl : TextDirection.ltr;

String ago(int ms) {
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}

final messengerKey = GlobalKey<ScaffoldMessengerState>();
void toast(String m) =>
    messengerKey.currentState?.showSnackBar(SnackBar(content: Text(m)));

Future<String?> pickImage({double maxWidth = 800}) async {
  final f = await ImagePicker().pickImage(
      source: ImageSource.gallery, maxWidth: maxWidth, imageQuality: 60);
  if (f == null) return null;
  final b = base64Encode(await f.readAsBytes());
  if (b.length > 450000) {
    toast('That photo is too large. Choose a smaller one.');
    return null;
  }
  return b;
}

final _imgCache = <String, MemoryImage>{};
MemoryImage? img(String? b) => (b == null || b.isEmpty)
    ? null
    : _imgCache.putIfAbsent(b, () => MemoryImage(base64Decode(b)));

Future<bool> confirm(BuildContext c, String msg) async =>
    (await showDialog<bool>(
        context: c,
        builder: (d) => AlertDialog(content: Text(msg), actions: [
              TextButton(
                  onPressed: () => Navigator.pop(d, false),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () => Navigator.pop(d, true),
                  child: const Text('Delete')),
            ]))) ??
    false;

Widget box(Widget child) => Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 6)],
      ),
      child: child,
    );

class Avatar extends StatelessWidget {
  final String? photo;
  final double r;
  const Avatar(this.photo, this.r, {super.key});
  @override
  Widget build(BuildContext c) => CircleAvatar(
        radius: r,
        backgroundColor: const Color(0xFFCED0D4),
        backgroundImage: img(photo),
        child: (photo == null || photo!.isEmpty)
            ? Icon(Icons.person, size: r, color: Colors.white)
            : null,
      );
}

// ───────────────────────── models ─────────────────────────

class Profile {
  final String id, name, subtitle, intro;
  final String? photo, cover;
  final List<String> followers;
  final bool liked, following;
  Profile({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.intro,
    required this.photo,
    required this.cover,
    required this.followers,
    required this.liked,
    required this.following,
  });
  factory Profile.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final j = d.data() ?? {};
    return Profile(
      id: d.id,
      name: j['name'] ?? '',
      subtitle: j['subtitle'] ?? '',
      intro: j['intro'] ?? '',
      photo: j['photo'],
      cover: j['cover'],
      followers: List<String>.from(j['followers'] ?? []),
      liked: j['liked'] ?? true,
      following: j['following'] ?? true,
    );
  }
}

class Post {
  final String id, text;
  final String? image;
  final int created, shares, commentCount;
  final Map<String, int> reactions;
  Post({
    required this.id,
    required this.text,
    required this.image,
    required this.created,
    required this.shares,
    required this.commentCount,
    required this.reactions,
  });
  factory Post.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final j = d.data();
    final r = <String, int>{};
    (j['reactions'] as Map?)?.forEach((k, v) => r[k.toString()] = (v as num).toInt());
    return Post(
      id: d.id,
      text: j['text'] ?? '',
      image: j['image'],
      created: j['created'] ?? 0,
      shares: j['shares'] ?? 0,
      commentCount: j['commentCount'] ?? 0,
      reactions: r,
    );
  }
}

class Comment {
  final String id, authorId, authorName, text;
  final int created, likes;
  Comment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.text,
    required this.created,
    required this.likes,
  });
  factory Comment.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final j = d.data();
    return Comment(
      id: d.id,
      authorId: j['authorId'] ?? 'me',
      authorName: j['authorName'] ?? 'Guest',
      text: j['text'] ?? '',
      created: j['created'] ?? 0,
      likes: j['likes'] ?? 0,
    );
  }
}

// ───────────────────────── live data ─────────────────────────

class Store extends ChangeNotifier {
  List<Profile> profiles = [];
  bool ready = false;
  String? error;

  void start() {
    profilesCol.orderBy('created').snapshots().listen((s) {
      profiles = s.docs.map(Profile.fromDoc).toList();
      ready = true;
      error = null;
      notifyListeners();
    }, onError: (e) {
      error = e.toString();
      ready = true;
      notifyListeners();
    });
  }

  Profile? byId(String id) {
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }
}

final store = Store();

// What this device has reacted to (kept on this phone only).
class Local extends ChangeNotifier {
  Map<String, String> reacts = {};
  Set<String> likedComments = {};

  Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      reacts = Map<String, String>.from(jsonDecode(sp.getString('reacts') ?? '{}'));
      likedComments = (sp.getStringList('cl') ?? []).toSet();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('reacts', jsonEncode(reacts));
      await sp.setStringList('cl', likedComments.toList());
    } catch (_) {}
  }

  void setReact(String postId, String? r) {
    if (r == null) {
      reacts.remove(postId);
    } else {
      reacts[postId] = r;
    }
    notifyListeners();
    _save();
  }

  void toggleCommentLike(String id) {
    if (!likedComments.remove(id)) likedComments.add(id);
    notifyListeners();
    _save();
  }
}

final local = Local();

Future<void> deleteProfile(Profile p) async {
  final posts = await profilesCol.doc(p.id).collection('posts').get();
  for (final d in posts.docs) {
    final cs = await d.reference.collection('comments').get();
    for (final c in cs.docs) {
      await c.reference.delete();
    }
    await d.reference.delete();
  }
  final others =
      await profilesCol.where('followers', arrayContains: p.id).get();
  for (final o in others.docs) {
    await o.reference.update({'followers': FieldValue.arrayRemove([p.id])});
  }
  await profilesCol.doc(p.id).delete();
}

// ───────────────────────── app ─────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (firebaseOptions.apiKey.startsWith('PASTE')) {
    runApp(const MaterialApp(
        home: Scaffold(
            body: Center(
                child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
          'Paste your Firebase web config into firebaseOptions at the top of lib/main.dart.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18)),
    )))));
    return;
  }
  await Firebase.initializeApp(options: firebaseOptions);
  await local.load();
  store.start();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'Saints profiles',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: messengerKey,
        theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: fbBlue,
            scaffoldBackgroundColor: pageBg),
        home: const Home(),
      );
}

// ───────────────────────── home ─────────────────────────

class Home extends StatelessWidget {
  const Home({super.key});

  Widget body(BuildContext c) {
    if (!store.ready) return const Center(child: CircularProgressIndicator());
    if (store.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
              'Could not load profiles.\nCheck that Firestore is created and its rules allow access.\n\n${store.error}',
              textAlign: TextAlign.center),
        ),
      );
    }
    if (store.profiles.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No profiles yet.\nTap “Add profile” to create the first one.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Colors.black54),
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 90),
          children: [
            for (final p in store.profiles)
              Card(
                color: Colors.white,
                margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: ListTile(
                  leading: Avatar(p.photo, 26),
                  title: Text(p.name,
                      textDirection: dirOf(p.name),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('${p.followers.length} followers'),
                  onTap: () => Navigator.push(c,
                      MaterialPageRoute(builder: (_) => ProfileScreen(p.id))),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext c) => ListenableBuilder(
        listenable: store,
        builder: (c, _) => Scaffold(
          appBar: AppBar(
            backgroundColor: fbBlue,
            foregroundColor: Colors.white,
            title: const Text('Saints',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          floatingActionButton: FloatingActionButton.extended(
            backgroundColor: fbBlue,
            foregroundColor: Colors.white,
            onPressed: () => Navigator.push(
                c, MaterialPageRoute(builder: (_) => const ProfileForm())),
            icon: const Icon(Icons.add),
            label: const Text('Add profile'),
          ),
          body: body(c),
        ),
      );
}

// ───────────────────────── add / edit profile ─────────────────────────

class ProfileForm extends StatefulWidget {
  final Profile? existing;
  const ProfileForm({super.key, this.existing});
  @override
  State<ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<ProfileForm> {
  late final name = TextEditingController(text: widget.existing?.name ?? '');
  late final sub = TextEditingController(text: widget.existing?.subtitle ?? '');
  late final intro = TextEditingController(text: widget.existing?.intro ?? '');
  late String? photo = widget.existing?.photo;
  late String? cover = widget.existing?.cover;

  void save() {
    if (name.text.trim().isEmpty) return;
    final data = {
      'name': name.text.trim(),
      'subtitle': sub.text.trim(),
      'intro': intro.text.trim(),
      'photo': photo,
      'cover': cover,
    };
    final e = widget.existing;
    if (e == null) {
      profilesCol.doc().set({
        ...data,
        'followers': <String>[],
        'liked': true,
        'following': true,
        'created': nowMs(),
      });
    } else {
      profilesCol.doc(e.id).update(data);
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(
          title: Text(widget.existing == null ? 'Add profile' : 'Edit profile'),
          actions: [TextButton(onPressed: save, child: const Text('Save'))],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Center(
                child: GestureDetector(
                  onTap: () async {
                    final b = await pickImage(maxWidth: 400);
                    if (b != null) setState(() => photo = b);
                  },
                  child: Stack(children: [
                    Avatar(photo, 56),
                    const Positioned(
                      right: 0,
                      bottom: 0,
                      child: CircleAvatar(
                          radius: 16,
                          backgroundColor: fbBlue,
                          child: Icon(Icons.camera_alt,
                              size: 16, color: Colors.white)),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              const Center(child: Text('Tap to choose a profile picture')),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () async {
                  final b = await pickImage(maxWidth: 900);
                  if (b != null) setState(() => cover = b);
                },
                icon: const Icon(Icons.image_outlined),
                label: Text(
                    cover == null ? 'Choose cover photo' : 'Change cover photo'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: name,
                onChanged: (_) => setState(() {}),
                textDirection: dirOf(name.text),
                decoration: const InputDecoration(
                    labelText: 'Name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: sub,
                onChanged: (_) => setState(() {}),
                textDirection: dirOf(sub.text),
                decoration: const InputDecoration(
                    labelText: 'Second name line (optional)',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: intro,
                onChanged: (_) => setState(() {}),
                textDirection: dirOf(intro.text),
                minLines: 4,
                maxLines: 8,
                decoration: const InputDecoration(
                    labelText: 'Intro (one fact per line)',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder()),
              ),
            ]),
          ),
        ),
      );
}

// ───────────────────────── posts stream helper ─────────────────────────

class PostsBuilder extends StatefulWidget {
  final String profileId;
  final Widget Function(BuildContext, List<Post>) builder;
  const PostsBuilder({super.key, required this.profileId, required this.builder});
  @override
  State<PostsBuilder> createState() => _PostsBuilderState();
}

class _PostsBuilderState extends State<PostsBuilder> {
  late final Stream<QuerySnapshot<Map<String, dynamic>>> stream = profilesCol
      .doc(widget.profileId)
      .collection('posts')
      .orderBy('created', descending: true)
      .snapshots();

  @override
  Widget build(BuildContext c) =>
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (c, s) {
          if (s.hasError) return box(Text('Could not load posts.\n${s.error}'));
          if (!s.hasData) {
            return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()));
          }
          return widget.builder(c, s.data!.docs.map(Post.fromDoc).toList());
        },
      );
}

// ───────────────────────── profile page ─────────────────────────

class ProfileScreen extends StatefulWidget {
  final String id;
  const ProfileScreen(this.id, {super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  int tab = 0;

  DocumentReference<Map<String, dynamic>> get ref => profilesCol.doc(widget.id);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (c, _) {
          final p = store.byId(widget.id);
          if (p == null) {
            return Scaffold(
                appBar: AppBar(),
                body: Center(
                    child: store.ready
                        ? const Text('Profile not found')
                        : const CircularProgressIndicator()));
          }
          return Scaffold(
            appBar: AppBar(
              backgroundColor: fbBlue,
              foregroundColor: Colors.white,
              title: Text(p.name, textDirection: dirOf(p.name)),
              actions: [
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'edit') {
                      Navigator.push(
                          c,
                          MaterialPageRoute(
                              builder: (_) => ProfileForm(existing: p)));
                    } else if (v == 'del') {
                      if (await confirm(c, 'Delete this profile and all its posts?')) {
                        if (c.mounted) Navigator.pop(c);
                        deleteProfile(p);
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit profile')),
                    PopupMenuItem(value: 'del', child: Text('Delete profile')),
                  ],
                ),
              ],
            ),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
                  header(p),
                  if (tab == 0) ...[
                    introCard(p),
                    followersCard(p),
                    composerCard(p),
                    PostsBuilder(
                      profileId: p.id,
                      builder: (c, posts) => Column(children: [
                        for (final post in posts)
                          PostCard(key: ValueKey(post.id), profile: p, post: post),
                      ]),
                    ),
                  ],
                  if (tab == 1) aboutTab(p),
                  if (tab == 2) photosTab(p),
                ]),
              ),
            ),
          );
        },
      );

  Widget header(Profile p) {
    Widget btn(String label, IconData icon, bool blue, VoidCallback f) =>
        Expanded(
          child: FilledButton.icon(
            onPressed: f,
            icon: Icon(icon, size: 20),
            label: Text(label,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              backgroundColor: blue ? fbBlue : chipGrey,
              foregroundColor: blue ? Colors.white : Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        );

    const labels = ['Posts', 'About', 'Photos'];
    return Container(
      color: Colors.white,
      child: Column(children: [
        SizedBox(
          height: 270,
          child: Stack(children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 200,
              child: GestureDetector(
                onTap: () async {
                  final b = await pickImage(maxWidth: 900);
                  if (b != null) ref.update({'cover': b});
                },
                child: Container(
                  color: chipGrey,
                  child: img(p.cover) != null
                      ? Image(image: img(p.cover)!, fit: BoxFit.cover)
                      : const Center(
                          child: Icon(Icons.add_a_photo_outlined,
                              color: Colors.black38, size: 32)),
                ),
              ),
            ),
            Positioned(
              top: 134,
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: () async {
                    final b = await pickImage(maxWidth: 400);
                    if (b != null) ref.update({'photo': b});
                  },
                  child: CircleAvatar(
                      radius: 66,
                      backgroundColor: Colors.white,
                      child: Avatar(p.photo, 62)),
                ),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(p.name,
              textAlign: TextAlign.center,
              textDirection: dirOf(p.name),
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        ),
        if (p.subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 16, right: 16),
            child: Text(p.subtitle,
                textAlign: TextAlign.center,
                textDirection: dirOf(p.subtitle),
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Colors.black54)),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            btn(p.liked ? 'Liked' : 'Like', Icons.thumb_up, p.liked,
                () => ref.update({'liked': !p.liked})),
            const SizedBox(width: 12),
            btn(p.following ? 'Unfollow' : 'Follow',
                p.following ? Icons.check : Icons.add, !p.following,
                () => ref.update({'following': !p.following})),
          ]),
        ),
        const Divider(height: 1),
        Row(children: [
          for (var i = 0; i < 3; i++)
            InkWell(
              onTap: () => setState(() => tab = i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                decoration: BoxDecoration(
                  border: Border(
                      bottom: BorderSide(
                          width: 3,
                          color: tab == i ? fbBlue : Colors.transparent)),
                ),
                child: Text(labels[i],
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: tab == i ? fbBlue : Colors.black54)),
              ),
            ),
        ]),
      ]),
    );
  }

  Widget introCard(Profile p) {
    final lines = p.intro.split('\n').where((l) => l.trim().isNotEmpty).toList();
    return box(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Intro', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      if (lines.isEmpty)
        const Text('Add an intro from the menu → Edit profile.',
            style: TextStyle(color: Colors.black54)),
      for (final l in lines)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SizedBox(
            width: double.infinity,
            child: Text(l,
                textAlign: TextAlign.center,
                textDirection: dirOf(l),
                style: const TextStyle(fontSize: 17, height: 1.4)),
          ),
        ),
    ]));
  }

  Widget followersCard(Profile p) {
    final fs = p.followers.map(store.byId).whereType<Profile>().toList();
    return box(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Followers',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      Text('${fs.length} people follow this page',
          style: const TextStyle(color: Colors.black54, fontSize: 16)),
      const SizedBox(height: 12),
      if (fs.isNotEmpty)
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 0.78,
          children: [
            for (final f in fs)
              InkWell(
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => ProfileScreen(f.id))),
                onLongPress: () async {
                  if (await confirm(context, 'Remove ${f.name} from followers?')) {
                    ref.update({'followers': FieldValue.arrayRemove([f.id])});
                  }
                },
                child: Column(children: [
                  Avatar(f.photo, 44),
                  const SizedBox(height: 6),
                  Text(f.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      textDirection: dirOf(f.name),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
              ),
          ],
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => addFollower(p),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add follower'),
      ),
      if (fs.isNotEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Long-press a follower to remove',
              style: TextStyle(color: Colors.black45, fontSize: 12)),
        ),
    ]));
  }

  void addFollower(Profile p) {
    final cands = store.profiles
        .where((o) => o.id != p.id && !p.followers.contains(o.id))
        .toList();
    if (cands.isEmpty) {
      toast('Create more profiles from the home screen first.');
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (s) => ListView(children: [
        for (final o in cands)
          ListTile(
            leading: Avatar(o.photo, 22),
            title: Text(o.name, textDirection: dirOf(o.name)),
            onTap: () {
              ref.update({'followers': FieldValue.arrayUnion([o.id])});
              Navigator.pop(s);
            },
          ),
      ]),
    );
  }

  Widget composerCard(Profile p) => box(Row(children: [
        Avatar(p.photo, 20),
        const SizedBox(width: 10),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => _Composer(p),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                  color: chipGrey, borderRadius: BorderRadius.circular(24)),
              child: const Text('What’s on your mind?',
                  style: TextStyle(color: Colors.black54, fontSize: 16)),
            ),
          ),
        ),
      ]));

  Widget aboutTab(Profile p) =>
      box(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('About',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Text(p.name,
            textDirection: dirOf(p.name),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        if (p.subtitle.isNotEmpty)
          Text(p.subtitle,
              textDirection: dirOf(p.subtitle),
              style: const TextStyle(fontSize: 16, color: Colors.black54)),
        const SizedBox(height: 12),
        for (final l in p.intro.split('\n').where((l) => l.trim().isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SizedBox(
              width: double.infinity,
              child: Text(l,
                  textDirection: dirOf(l),
                  style: const TextStyle(fontSize: 16, height: 1.4)),
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ProfileForm(existing: p))),
          icon: const Icon(Icons.edit),
          label: const Text('Edit profile'),
        ),
      ]));

  Widget photosTab(Profile p) => PostsBuilder(
        profileId: p.id,
        builder: (c, posts) {
          final all = <String>[
            if (p.photo != null && p.photo!.isNotEmpty) p.photo!,
            if (p.cover != null && p.cover!.isNotEmpty) p.cover!,
            for (final post in posts)
              if (post.image != null && post.image!.isNotEmpty) post.image!,
          ];
          return box(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Photos',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            if (all.isEmpty)
              const Text('No photos yet.', style: TextStyle(color: Colors.black54)),
            GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final b in all) Image(image: img(b)!, fit: BoxFit.cover),
              ],
            ),
          ]));
        },
      );
}

// ───────────────────────── create post sheet ─────────────────────────

class _Composer extends StatefulWidget {
  final Profile p;
  const _Composer(this.p);
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final t = TextEditingController();
  String? image;

  void post() {
    if (t.text.trim().isEmpty && image == null) return;
    profilesCol.doc(widget.p.id).collection('posts').add({
      'text': t.text.trim(),
      'image': image,
      'created': nowMs(),
      'reactions': <String, int>{},
      'shares': 0,
      'commentCount': 0,
    });
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext c) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Avatar(widget.p.photo, 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.p.name,
                    textDirection: dirOf(widget.p.name),
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ]),
            TextField(
              controller: t,
              autofocus: true,
              minLines: 3,
              maxLines: 6,
              onChanged: (_) => setState(() {}),
              textDirection: dirOf(t.text),
              decoration: const InputDecoration(
                  hintText: 'What’s on your mind?', border: InputBorder.none),
            ),
            if (image != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Image(image: img(image)!, height: 150),
              ),
            Row(children: [
              TextButton.icon(
                onPressed: () async {
                  final b = await pickImage();
                  if (b != null) setState(() => image = b);
                },
                icon: const Icon(Icons.photo_library, color: Colors.green),
                label: const Text('Photo'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: post,
                style: FilledButton.styleFrom(backgroundColor: fbBlue),
                child: const Text('Post'),
              ),
            ]),
          ]),
        ),
      );
}

// ───────────────────────── a post with reactions + comments ─────────────────────────

class PostCard extends StatefulWidget {
  final Profile profile;
  final Post post;
  const PostCard({super.key, required this.profile, required this.post});
  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  bool open = false;
  String as = 'me';
  final ctl = TextEditingController();

  Post get post => widget.post;

  DocumentReference<Map<String, dynamic>> get ref =>
      profilesCol.doc(widget.profile.id).collection('posts').doc(post.id);

  late final Stream<QuerySnapshot<Map<String, dynamic>>> commentsStream =
      ref.collection('comments').orderBy('created').snapshots();

  void react(String? r) {
    final old = local.reacts[post.id];
    if (r == old) r = null;
    final up = <String, dynamic>{};
    if (old != null) up['reactions.$old'] = FieldValue.increment(-1);
    if (r != null) up['reactions.$r'] = FieldValue.increment(1);
    if (up.isNotEmpty) ref.update(up);
    local.setReact(post.id, r);
  }

  void pickReaction() => showDialog(
        context: context,
        builder: (d) => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(alignment: WrapAlignment.center, children: [
              for (final e in emojis.entries)
                IconButton(
                  tooltip: e.key,
                  onPressed: () {
                    Navigator.pop(d);
                    react(e.key);
                  },
                  icon: Text(e.value, style: const TextStyle(fontSize: 30)),
                ),
            ]),
          ),
        ),
      );

  void send() {
    final t = ctl.text.trim();
    if (t.isEmpty) return;
    final who = as == 'me' ? null : store.byId(as);
    ref.collection('comments').add({
      'authorId': who?.id ?? 'me',
      'authorName': who?.name ?? 'Guest',
      'text': t,
      'created': nowMs(),
      'likes': 0,
    });
    ref.update({'commentCount': FieldValue.increment(1)});
    ctl.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: local,
        builder: (c, _) => content(c),
      );

  Widget content(BuildContext context) {
    final p = widget.profile;
    final counts = post.reactions.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = counts.fold(0, (a, e) => a + e.value);
    final top = counts.take(3).map((e) => emojis[e.key] ?? '').join();
    final mine = local.reacts[post.id];

    Widget action(Widget icon, String label, VoidCallback f,
            {VoidCallback? long, Color? color}) =>
        Expanded(
          child: InkWell(
            onTap: f,
            onLongPress: long,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                icon,
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: color ?? Colors.black54)),
              ]),
            ),
          ),
        );

    return box(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Avatar(p.photo, 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name,
                textDirection: dirOf(p.name),
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(ago(post.created),
                style: const TextStyle(color: Colors.black54, fontSize: 12)),
          ]),
        ),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'del' && await confirm(context, 'Delete this post?')) {
              final cs = await ref.collection('comments').get();
              for (final d in cs.docs) {
                await d.reference.delete();
              }
              await ref.delete();
            }
          },
          itemBuilder: (_) =>
              const [PopupMenuItem(value: 'del', child: Text('Delete post'))],
        ),
      ]),
      if (post.text.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: SizedBox(
            width: double.infinity,
            child: Text(post.text,
                textDirection: dirOf(post.text),
                style: const TextStyle(fontSize: 17, height: 1.4)),
          ),
        ),
      if (img(post.image) != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image(
                image: img(post.image)!,
                width: double.infinity,
                fit: BoxFit.cover),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(children: [
          if (total > 0) Text('$top $total', style: const TextStyle(fontSize: 14)),
          const Spacer(),
          Text('${post.commentCount} comments · ${post.shares} shares',
              style: const TextStyle(color: Colors.black54, fontSize: 13)),
        ]),
      ),
      const Divider(height: 14),
      Row(children: [
        action(
          mine == null
              ? const Icon(Icons.thumb_up_outlined, size: 20, color: Colors.black54)
              : Text(emojis[mine] ?? '👍', style: const TextStyle(fontSize: 18)),
          mine ?? 'Like',
          () => react(mine == null ? 'Like' : null),
          long: pickReaction,
          color: mine == null ? null : fbBlue,
        ),
        action(const Icon(Icons.mode_comment_outlined, size: 20, color: Colors.black54),
            'Comment', () => setState(() => open = !open)),
        action(const Icon(Icons.share_outlined, size: 20, color: Colors.black54), 'Share',
            () {
          ref.update({'shares': FieldValue.increment(1)});
          toast('Shared');
        }),
      ]),
      if (open) ...[
        const Divider(height: 14),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: commentsStream,
          builder: (c, s) {
            if (!s.hasData) {
              return const Padding(
                  padding: EdgeInsets.all(8),
                  child: Center(child: CircularProgressIndicator()));
            }
            final cms = s.data!.docs.map(Comment.fromDoc).toList();
            return Column(children: [for (final cm in cms) commentTile(cm)]);
          },
        ),
        const SizedBox(height: 10),
        commentInput(),
      ],
    ]));
  }

  Widget commentTile(Comment cm) {
    final a = cm.authorId == 'me' ? null : store.byId(cm.authorId);
    final name = a?.name ?? cm.authorName;
    final liked = local.likedComments.contains(cm.id);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Avatar(a?.photo, 16),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            GestureDetector(
              onLongPress: () async {
                if (await confirm(context, 'Delete this comment?')) {
                  ref.collection('comments').doc(cm.id).delete();
                  ref.update({'commentCount': FieldValue.increment(-1)});
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: chipGrey, borderRadius: BorderRadius.circular(16)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name,
                      textDirection: dirOf(name),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  SizedBox(
                    width: double.infinity,
                    child: Text(cm.text,
                        textDirection: dirOf(cm.text),
                        style: const TextStyle(fontSize: 15)),
                  ),
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Row(children: [
                Text(ago(cm.created),
                    style: const TextStyle(color: Colors.black54, fontSize: 12)),
                const SizedBox(width: 14),
                InkWell(
                  onTap: () {
                    ref.collection('comments').doc(cm.id).update(
                        {'likes': FieldValue.increment(liked ? -1 : 1)});
                    local.toggleCommentLike(cm.id);
                  },
                  child: Text('Like',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: liked ? fbBlue : Colors.black54)),
                ),
                if (cm.likes > 0)
                  Text('  👍 ${cm.likes}', style: const TextStyle(fontSize: 12)),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget commentInput() {
    final who = as == 'me' ? null : store.byId(as);
    return Row(children: [
      PopupMenuButton<String>(
        tooltip: 'Comment as',
        onSelected: (v) => setState(() => as = v),
        itemBuilder: (_) => [
          const PopupMenuItem(
              value: 'me',
              child: Row(children: [Avatar(null, 14), SizedBox(width: 8), Text('Guest')])),
          for (final q in store.profiles)
            PopupMenuItem(
              value: q.id,
              child: Row(children: [
                Avatar(q.photo, 14),
                const SizedBox(width: 8),
                Flexible(child: Text(q.name, overflow: TextOverflow.ellipsis)),
              ]),
            ),
        ],
        child: Avatar(who?.photo, 17),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: TextField(
          controller: ctl,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => send(),
          textDirection: dirOf(ctl.text),
          decoration: InputDecoration(
            hintText: 'Write a comment…',
            isDense: true,
            filled: true,
            fillColor: chipGrey,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
          ),
        ),
      ),
      IconButton(onPressed: send, icon: const Icon(Icons.send, color: fbBlue)),
    ]);
  }
}