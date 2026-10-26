import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

String uid() => DateTime.now().microsecondsSinceEpoch.toString();

TextDirection dirOf(String s) =>
    RegExp(r'[\u0600-\u06FF]').hasMatch(s) ? TextDirection.rtl : TextDirection.ltr;

String ago(String iso) {
  final d = DateTime.now().difference(DateTime.parse(iso));
  if (d.inMinutes < 1) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}

Future<String?> pickImage({double maxWidth = 800}) async {
  final f = await ImagePicker().pickImage(
      source: ImageSource.gallery, maxWidth: maxWidth, imageQuality: 70);
  if (f == null) return null;
  return base64Encode(await f.readAsBytes());
}

final _imgCache = <String, MemoryImage>{};
MemoryImage? img(String? b) => b == null
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
        child: photo == null ? Icon(Icons.person, size: r, color: Colors.white) : null,
      );
}

// ───────────────────────── models ─────────────────────────

class Comment {
  final String id, authorId, authorName, text, time;
  int likes;
  bool liked;
  Comment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.text,
    required this.time,
    this.likes = 0,
    this.liked = false,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'authorId': authorId,
        'authorName': authorName,
        'text': text,
        'time': time,
        'likes': likes,
        'liked': liked,
      };
  factory Comment.fromJson(Map<String, dynamic> j) => Comment(
        id: j['id'],
        authorId: j['authorId'],
        authorName: j['authorName'],
        text: j['text'],
        time: j['time'],
        likes: j['likes'] ?? 0,
        liked: j['liked'] ?? false,
      );
}

class Post {
  final String id, time;
  String text;
  String? image;
  Map<String, int> reactions;
  String? myReaction;
  List<Comment> comments;
  int shares;
  Post({
    required this.id,
    required this.time,
    this.text = '',
    this.image,
    Map<String, int>? reactions,
    this.myReaction,
    List<Comment>? comments,
    this.shares = 0,
  })  : reactions = reactions ?? {},
        comments = comments ?? [];
  Map<String, dynamic> toJson() => {
        'id': id,
        'time': time,
        'text': text,
        'image': image,
        'reactions': reactions,
        'myReaction': myReaction,
        'comments': comments.map((c) => c.toJson()).toList(),
        'shares': shares,
      };
  factory Post.fromJson(Map<String, dynamic> j) => Post(
        id: j['id'],
        time: j['time'],
        text: j['text'] ?? '',
        image: j['image'],
        reactions: Map<String, int>.from(j['reactions'] ?? {}),
        myReaction: j['myReaction'],
        comments: ((j['comments'] ?? []) as List)
            .map((e) => Comment.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        shares: j['shares'] ?? 0,
      );
}

class Profile {
  final String id;
  String name, subtitle, intro;
  String? photo, cover;
  List<String> followers;
  List<Post> posts;
  bool liked, following;
  Profile({
    required this.id,
    required this.name,
    this.subtitle = '',
    this.intro = '',
    this.photo,
    this.cover,
    List<String>? followers,
    List<Post>? posts,
    this.liked = true,
    this.following = true,
  })  : followers = followers ?? [],
        posts = posts ?? [];
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'subtitle': subtitle,
        'intro': intro,
        'photo': photo,
        'cover': cover,
        'followers': followers,
        'posts': posts.map((p) => p.toJson()).toList(),
        'liked': liked,
        'following': following,
      };
  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'],
        name: j['name'],
        subtitle: j['subtitle'] ?? '',
        intro: j['intro'] ?? '',
        photo: j['photo'],
        cover: j['cover'],
        followers: List<String>.from(j['followers'] ?? []),
        posts: ((j['posts'] ?? []) as List)
            .map((e) => Post.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        liked: j['liked'] ?? true,
        following: j['following'] ?? true,
      );
}

// ───────────────────────── store (saved in the browser) ─────────────────────────

class Store extends ChangeNotifier {
  List<Profile> profiles = [];

  Profile? byId(String id) {
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final s = sp.getString('data');
      if (s != null) {
        profiles = (jsonDecode(s) as List)
            .map((e) => Profile.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (e) {
      debugPrint('load failed: $e');
    }
    notifyListeners();
  }

  void change() {
    notifyListeners();
    _save();
  }

  Future<void> _save() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
          'data', jsonEncode(profiles.map((p) => p.toJson()).toList()));
    } catch (e) {
      debugPrint('save failed: $e');
    }
  }
}

final store = Store();

// ───────────────────────── app ─────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.load();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'Saints profiles',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: fbBlue,
            scaffoldBackgroundColor: pageBg),
        home: const Home(),
      );
}

// ───────────────────────── home (list of profiles) ─────────────────────────

class Home extends StatelessWidget {
  const Home({super.key});
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
          body: store.profiles.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No profiles yet.\nTap “Add profile” to create the first one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, color: Colors.black54),
                    ),
                  ),
                )
              : Center(
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
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                              subtitle: Text(
                                  '${p.followers.length} followers · ${p.posts.length} posts'),
                              onTap: () => Navigator.push(
                                  c,
                                  MaterialPageRoute(
                                      builder: (_) => ProfileScreen(p.id))),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
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
    final e = widget.existing;
    if (e == null) {
      store.profiles.add(Profile(
        id: uid(),
        name: name.text.trim(),
        subtitle: sub.text.trim(),
        intro: intro.text.trim(),
        photo: photo,
        cover: cover,
      ));
    } else {
      e.name = name.text.trim();
      e.subtitle = sub.text.trim();
      e.intro = intro.text.trim();
      e.photo = photo;
      e.cover = cover;
    }
    store.change();
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
                    final b = await pickImage(maxWidth: 500);
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
                  final b = await pickImage(maxWidth: 1000);
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

// ───────────────────────── profile page ─────────────────────────

class ProfileScreen extends StatefulWidget {
  final String id;
  const ProfileScreen(this.id, {super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  int tab = 0;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (c, _) {
          final p = store.byId(widget.id);
          if (p == null) return const Scaffold();
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
                        for (final o in store.profiles) {
                          o.followers.remove(p.id);
                        }
                        store.profiles.remove(p);
                        store.change();
                        if (c.mounted) Navigator.pop(c);
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
                  if (tab == 0) ...postsTab(p),
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
                  final b = await pickImage(maxWidth: 1000);
                  if (b != null) {
                    p.cover = b;
                    store.change();
                  }
                },
                child: Container(
                  color: chipGrey,
                  child: p.cover != null
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
                    final b = await pickImage(maxWidth: 500);
                    if (b != null) {
                      p.photo = b;
                      store.change();
                    }
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
            btn(p.liked ? 'Liked' : 'Like', Icons.thumb_up, p.liked, () {
              p.liked = !p.liked;
              store.change();
            }),
            const SizedBox(width: 12),
            btn(p.following ? 'Unfollow' : 'Follow',
                p.following ? Icons.check : Icons.add, !p.following, () {
              p.following = !p.following;
              store.change();
            }),
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

  // ── Posts tab ──

  List<Widget> postsTab(Profile p) => [
        introCard(p),
        followersCard(p),
        composerCard(p),
        for (final post in p.posts)
          PostCard(key: ValueKey(post.id), profile: p, post: post),
      ];

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
                    p.followers.remove(f.id);
                    store.change();
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Create more profiles from the home screen first.')));
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
              p.followers.add(o.id);
              store.change();
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

  // ── About tab ──

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

  // ── Photos tab ──

  Widget photosTab(Profile p) {
    final all = <String>[
      if (p.photo != null) p.photo!,
      if (p.cover != null) p.cover!,
      for (final post in p.posts)
        if (post.image != null) post.image!,
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
  }
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
    widget.p.posts.insert(
        0,
        Post(
          id: uid(),
          time: DateTime.now().toIso8601String(),
          text: t.text.trim(),
          image: image,
        ));
    store.change();
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

  void react(String? r) {
    final old = post.myReaction;
    if (old != null) {
      post.reactions[old] = (post.reactions[old] ?? 1) - 1;
      if (post.reactions[old]! <= 0) post.reactions.remove(old);
    }
    if (r != null) post.reactions[r] = (post.reactions[r] ?? 0) + 1;
    post.myReaction = r;
    store.change();
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
    post.comments.add(Comment(
      id: uid(),
      authorId: who?.id ?? 'me',
      authorName: who?.name ?? 'You',
      text: t,
      time: DateTime.now().toIso8601String(),
    ));
    ctl.clear();
    store.change();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final total = post.reactions.values.fold(0, (a, b) => a + b);
    final top = (post.reactions.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(3)
        .map((e) => emojis[e.key])
        .join();
    final mine = post.myReaction;

    Widget action(Widget icon, String label, VoidCallback f, {VoidCallback? long, Color? color}) =>
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
            Text(ago(post.time),
                style: const TextStyle(color: Colors.black54, fontSize: 12)),
          ]),
        ),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'del' && await confirm(context, 'Delete this post?')) {
              p.posts.remove(post);
              store.change();
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
      if (post.image != null)
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
          Text('${post.comments.length} comments · ${post.shares} shares',
              style: const TextStyle(color: Colors.black54, fontSize: 13)),
        ]),
      ),
      const Divider(height: 14),
      Row(children: [
        action(
          mine == null
              ? const Icon(Icons.thumb_up_outlined, size: 20, color: Colors.black54)
              : Text(emojis[mine]!, style: const TextStyle(fontSize: 18)),
          mine ?? 'Like',
          () => react(mine == null ? 'Like' : null),
          long: pickReaction,
          color: mine == null ? null : fbBlue,
        ),
        action(const Icon(Icons.mode_comment_outlined, size: 20, color: Colors.black54),
            'Comment', () => setState(() => open = !open)),
        action(const Icon(Icons.share_outlined, size: 20, color: Colors.black54), 'Share',
            () {
          post.shares++;
          store.change();
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Shared')));
        }),
      ]),
      if (open) ...[
        const Divider(height: 14),
        for (final cm in post.comments) commentTile(cm),
        const SizedBox(height: 10),
        commentInput(),
      ],
    ]));
  }

  Widget commentTile(Comment cm) {
    final a = cm.authorId == 'me' ? null : store.byId(cm.authorId);
    final name = a?.name ?? cm.authorName;
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
                  post.comments.remove(cm);
                  store.change();
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
                Text(ago(cm.time),
                    style: const TextStyle(color: Colors.black54, fontSize: 12)),
                const SizedBox(width: 14),
                InkWell(
                  onTap: () {
                    cm.liked = !cm.liked;
                    cm.likes += cm.liked ? 1 : -1;
                    store.change();
                  },
                  child: Text('Like',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: cm.liked ? fbBlue : Colors.black54)),
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
              child: Row(children: [Avatar(null, 14), SizedBox(width: 8), Text('You')])),
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