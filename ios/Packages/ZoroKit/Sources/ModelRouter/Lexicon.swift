import Foundation

/// Word lists for English, Hindi (Devanagari) and Hinglish (romanised Hindi). All entries are in the
/// normalised form produced by `Script.normalize` (no nukta, anusvara instead of chandrabindu).
enum Lexicon {
    // MARK: Language identification

    /// Romanised Hindi words that are not ordinary English words.
    static let romanHindiStrong: Set<String> = [
        "hai", "hain", "hoon", "tha", "thi", "nahi", "nahin", "nhi", "kya", "kyun", "kyu", "kab", "kahan", "kahaan", "kaun",
        "kaise", "kaisa", "kitna", "kitne", "kitni", "kal", "aaj", "parso", "abhi", "phir", "fir", "subah", "subha", "shaam",
        "sham", "raat", "dopahar", "baje", "mujhe", "mujhko", "mera", "meri", "mere", "tum", "tumhara", "tumhe", "aap", "aapka",
        "aapko", "hum", "humko", "hamara", "uska", "unka", "iska", "yeh", "ye", "woh", "kar", "karo", "karna", "karne", "kare",
        "kiya", "kijiye", "karenge", "dena", "dijiye", "dedo", "lena", "lelo", "laga", "lagao", "lagana", "lagado", "dikhao",
        "dikha", "dikhana", "batao", "bata", "batana", "bolo", "sunao", "suna", "chalao", "chala", "chalana", "bajao", "band",
        "shuru", "khol", "kholo", "kholna", "bhejo", "bhej", "bhejna", "dhundo", "dhoondo", "khojo", "dekho", "dekh", "dekhna",
        "yaad", "dilana", "dilao", "dila", "rakho", "rakh", "rakhna", "chahiye", "chahta", "chahti", "hona", "hoga", "hogi",
        "honge", "raha", "rahi", "rahe", "wala", "wali", "wale", "ka", "ki", "ke", "ko", "se", "mein", "pe", "tak", "aur", "lekin",
        "magar", "bhi", "toh", "na", "mat", "sirf", "bahut", "thoda", "zyada", "jyada", "accha", "acha", "theek", "thik", "bilkul",
        "kuch", "kuchh", "koi", "sab", "sabhi", "gaana", "gana", "gaane", "ghanta", "ghante", "din", "hafte", "hafta", "mahina",
        "mahine", "saal", "kharcha", "paisa", "paise", "rupaye", "ruko", "roko", "jao", "chalo", "bhai", "yaar", "dost", "liye",
        "wapas", "pehle", "pichle", "pichla", "agle", "agla", "agli", "ghar", "kaam", "naam", "baat", "bataiye", "boliye",
        "suniye", "samajh", "pata", "kyunki", "isliye", "jaldi", "jab", "tab", "jo", "apna", "apni", "apne", "mujhse", "tumse",
        "usse", "isse", "roz", "har", "dhai", "dedh", "aadha", "adha", "sava", "saade", "paune", "savva", "mummy", "papa",
        "utha", "uthana", "jaga", "jagana", "tasveer", "tasveerein", "peeche", "kholiye", "lagaiye", "bajaiye", "chaliye",
        "dikhaiye", "bhejiye", "kijiyega", "chahiye", "sunna", "dekhni", "milega", "milegi", "mila", "mili", "kitab", "dawai",
    ]

    /// Romanised Hindi words that are also English words: they count only next to a strong marker.
    static let romanHindiWeak: Set<String> = ["to", "me", "do", "he", "so", "par", "ya", "hi", "bas", "ab", "le", "is", "us", "in", "main"]

    static let englishFunction: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "to", "of", "in", "on", "at", "for", "with", "from", "my", "me", "i", "you",
        "it", "and", "or", "what", "when", "where", "who", "how", "show", "set", "play", "remind", "call", "open", "please",
        "can", "could", "will", "would", "my", "do", "does", "next", "last", "this", "that", "photo", "photos", "alarm", "timer",
    ]

    // MARK: Numbers

    /// Number words (English, romanised Hindi, Devanagari) up to 60.
    static let numberWords: [String: Int] = {
        var m: [String: Int] = [:]
        let english = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                       "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        for (i, w) in english.enumerated() { m[w] = i }
        for (w, v) in ["thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "twentyfive": 25, "fortyfive": 45] { m[w] = v }
        let hindiRoman: [(String, Int)] = [
            ("ek", 1), ("do", 2), ("teen", 3), ("char", 4), ("chaar", 4), ("paanch", 5), ("panch", 5), ("chhe", 6), ("chhah", 6),
            ("che", 6), ("chah", 6), ("chhey", 6), ("saat", 7), ("aath", 8), ("nau", 9), ("das", 10), ("gyarah", 11),
            ("barah", 12), ("terah", 13), ("chaudah", 14), ("pandrah", 15), ("pandra", 15), ("solah", 16), ("satrah", 17),
            ("atharah", 18), ("unnis", 19), ("bees", 20), ("pachis", 25), ("tees", 30), ("chalis", 40), ("paintalis", 45),
            ("pachas", 50), ("pachaas", 50),
        ]
        for (w, v) in hindiRoman { m[w] = v }
        let devanagari: [(String, Int)] = [
            ("एक", 1), ("दो", 2), ("तीन", 3), ("चार", 4), ("पांच", 5), ("पाच", 5), ("छह", 6), ("छः", 6), ("छे", 6), ("छ", 6),
            ("सात", 7), ("आठ", 8), ("नौ", 9), ("दस", 10), ("ग्यारह", 11), ("बारह", 12), ("तेरह", 13), ("चौदह", 14),
            ("पंद्रह", 15), ("पन्द्रह", 15), ("सोलह", 16), ("सत्रह", 17), ("अठारह", 18), ("उन्नीस", 19), ("बीस", 20),
            ("पच्चीस", 25), ("तीस", 30), ("चालीस", 40), ("पैंतालीस", 45), ("पचास", 50),
        ]
        for (w, v) in devanagari { m[w] = v }
        return m
    }()

    /// Fraction prefixes: "dedh ghanta" (1.5), "dhai" (2.5), "aadha" (0.5).
    static let fractionWords: [String: Double] = [
        "dedh": 1.5, "डेढ": 1.5, "dhai": 2.5, "dhaai": 2.5, "ढाई": 2.5, "aadha": 0.5, "adha": 0.5, "aadhe": 0.5, "आधा": 0.5,
        "आधे": 0.5, "half": 0.5,
    ]
    /// "sava N" = N + 0.25, "saade N" = N + 0.5, "paune N" = N - 0.25.
    static let savaWords: Set<String> = ["sava", "savva", "सवा"]
    static let saadeWords: Set<String> = ["saade", "sade", "साढे"]
    static let pauneWords: Set<String> = ["paune", "poune", "पौने"]

    // MARK: Time units

    static let secondUnits: Set<String> = ["sec", "secs", "second", "seconds", "sekand", "सेकंड", "सेकण्ड", "सैकंड"]
    static let minuteUnits: Set<String> = ["min", "mins", "minute", "minutes", "minat", "mint", "minit", "मिनट", "मिनिट"]
    static let hourUnits: Set<String> = ["hr", "hrs", "hour", "hours", "ghanta", "ghante", "ghantey", "ghanton", "घंटा", "घंटे", "घण्टा", "घण्टे", "घंटों"]
    static let dayUnits: Set<String> = ["day", "days", "din", "दिन"]
    static let weekUnits: Set<String> = ["week", "weeks", "hafte", "hafta", "hafton", "हफ्ते", "हफ्ता", "सप्ताह", "हफ्तों"]
    static let monthUnits: Set<String> = ["month", "months", "mahine", "mahina", "महीने", "महीना", "महिने", "महीनों"]
    static let yearUnits: Set<String> = ["year", "years", "saal", "sal", "साल", "वर्ष"]

    // MARK: Clock words

    static let clockIndicators: Set<String> = ["baje", "baj", "bje", "बजे", "बज", "oclock", "bajkar", "बजकर"]
    static let amWords: Set<String> = ["am", "a.m"]
    static let pmWords: Set<String> = ["pm", "p.m"]
    static let morning: Set<String> = ["morning", "subah", "subha", "सुबह", "सवेरे", "savere"]
    static let afternoon: Set<String> = ["afternoon", "dopahar", "dophar", "दोपहर"]
    static let evening: Set<String> = ["evening", "shaam", "sham", "शाम"]
    static let night: Set<String> = ["night", "raat", "रात", "tonight", "tonite"]
    static let timePrepositions: Set<String> = ["at", "@", "by", "around", "before", "tak", "तक"]
    static let datePrepositions: Set<String> = ["on", "for", "by", "from", "of"]
    static let dateSuffixes: Set<String> = ["ko", "को", "tak", "तक", "par", "पर", "ke", "ka", "ki", "का", "की", "के", "ho", "se", "से"]
    static let durationLeads: Set<String> = ["in", "for", "after", "within"]
    static let durationTrails: Set<String> = ["baad", "बाद", "mein", "में", "me"]

    // MARK: Days

    static let today: Set<String> = ["today", "aaj", "आज"]
    static let tonight: Set<String> = ["tonight", "tonite"]
    static let tomorrow: Set<String> = ["tomorrow", "tmrw", "tmr", "tomorow", "tommorow", "tomorrow's"]
    static let yesterday: Set<String> = ["yesterday", "yday"]
    static let kal: Set<String> = ["kal", "कल"]
    static let parso: Set<String> = ["parso", "parson", "परसों", "परसो"]
    static let nextWords: Set<String> = ["next", "agle", "agla", "agli", "अगले", "अगला", "अगली", "upcoming"]
    static let lastWords: Set<String> = ["last", "previous", "pichle", "pichla", "pichli", "pichhle", "पिछले", "पिछला", "पिछली", "past"]
    static let thisWords: Set<String> = ["this", "is", "इस", "current"]
    static let repeatWords: Set<String> = ["every", "each", "har", "हर", "roz", "रोज", "daily", "everyday", "rozana", "रोजाना"]

    /// Weekday index follows `Calendar` (1 = Sunday ... 7 = Saturday).
    static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
        "ravivar": 1, "itwar": 1, "itvaar": 1, "somvar": 2, "somwar": 2, "mangalvar": 3, "mangalwar": 3, "budhvar": 4,
        "budhwar": 4, "guruvar": 5, "guruwar": 5, "veervar": 5, "brihaspativar": 5, "shukravar": 6, "shukrawar": 6,
        "shanivar": 7, "shaniwar": 7,
        "रविवार": 1, "सोमवार": 2, "मंगलवार": 3, "बुधवार": 4, "गुरुवार": 5, "बृहस्पतिवार": 5, "शुक्रवार": 6, "शनिवार": 7,
    ]
    static let weekdayCodes = [1: "sun", 2: "mon", 3: "tue", 4: "wed", 5: "thu", 6: "fri", 7: "sat"]
    static let weekdaysOnly: Set<String> = ["weekdays", "weekday"]
    static let weekends: Set<String> = ["weekend", "weekends", "वीकेंड"]

    static let months: [String: Int] = [
        "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8, "september": 9,
        "october": 10, "november": 11, "december": 12,
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
        "जनवरी": 1, "फरवरी": 2, "मार्च": 3, "अप्रैल": 4, "मई": 5, "जून": 6, "जुलाई": 7, "अगस्त": 8, "सितंबर": 9, "सितम्बर": 9,
        "अक्टूबर": 10, "अक्तूबर": 10, "नवंबर": 11, "नवम्बर": 11, "दिसंबर": 12, "दिसम्बर": 12,
        "janvari": 1, "farvari": 2, "agast": 8, "sitambar": 9, "aktubar": 10, "navambar": 11, "disambar": 12,
    ]
    /// Month names that are also ordinary words: only read as a month next to a day number.
    static let ambiguousMonths: Set<String> = ["may", "mar", "sat", "sun", "jan", "dec", "oct", "aug"]
    static let ordinalSuffixes: Set<String> = ["st", "nd", "rd", "th"]

    // MARK: Photos

    static let photoNouns: Set<String> = [
        "photo", "photos", "pic", "pics", "picture", "pictures", "image", "images", "selfie", "selfies", "फोटो", "फोटोज", "तस्वीर",
        "तस्वीरें", "तस्वीरे", "तसवीर", "तसवीरें", "पिक्चर", "फोटोस", "tasveer", "tasveerein", "tasvir", "photu",
    ]
    static let screenshotNouns: Set<String> = ["screenshot", "screenshots", "स्क्रीनशॉट", "स्क्रीनशॉट्स", "screenshoot"]
    static let photoBlockers: Set<String> = [
        "take", "click", "capture", "print", "edit", "delete", "upload", "send", "share", "kheencho", "kheench", "khicho", "खींचो",
        "खींच", "bhejo", "bhej", "भेजो", "भेज", "hatao", "delete", "mita", "मिटा", "camera", "कैमरा",
    ]

    static let colors: [String: String] = [
        "red": "red", "blue": "blue", "green": "green", "yellow": "yellow", "black": "black", "white": "white",
        "orange": "orange", "pink": "pink", "purple": "purple", "brown": "brown", "grey": "gray", "gray": "gray",
        "beige": "beige", "golden": "gold", "gold": "gold", "silver": "silver", "maroon": "maroon",
        "laal": "red", "lal": "red", "neela": "blue", "neeli": "blue", "neele": "blue", "hara": "green", "hari": "green",
        "peela": "yellow", "peeli": "yellow", "kaala": "black", "kaali": "black", "kala": "black", "kali": "black",
        "safed": "white", "narangi": "orange", "gulabi": "pink", "baingani": "purple", "bhura": "brown", "bhoora": "brown",
        "लाल": "red", "नीला": "blue", "नीली": "blue", "नीले": "blue", "हरा": "green", "हरी": "green", "हरे": "green",
        "पीला": "yellow", "पीली": "yellow", "पीले": "yellow", "काला": "black", "काली": "black", "काले": "black",
        "सफेद": "white", "नारंगी": "orange", "गुलाबी": "pink", "बैंगनी": "purple", "भूरा": "brown", "भूरी": "brown",
        "स्लेटी": "gray", "ग्रे": "gray", "सुनहरा": "gold",
    ]

    /// Object words (English, Hinglish, Hindi) to the labels the photo index uses.
    static let photoLabels: [String: [String]] = [
        "cap": ["cap", "hat"], "hat": ["cap", "hat"], "topi": ["cap", "hat"], "टोपी": ["cap", "hat"],
        "dog": ["dog"], "puppy": ["dog"], "kutta": ["dog"], "kutte": ["dog"], "कुत्ता": ["dog"], "कुत्ते": ["dog"],
        "cat": ["cat"], "kitten": ["cat"], "billi": ["cat"], "बिल्ली": ["cat"],
        "car": ["car", "vehicle"], "कार": ["car", "vehicle"], "gaadi": ["car", "vehicle"], "gadi": ["car", "vehicle"], "गाडी": ["car", "vehicle"], 
        "bike": ["motorcycle", "bicycle"], "motorcycle": ["motorcycle"], "cycle": ["bicycle"], "bicycle": ["bicycle"],
        "food": ["food"], "khana": ["food"], "खाना": ["food"], "pizza": ["pizza", "food"], "cake": ["cake", "food"],
        "beach": ["beach", "sea"], "sea": ["sea", "beach"], "samundar": ["sea", "beach"], "समुद्र": ["sea", "beach"],
        "mountain": ["mountain"], "mountains": ["mountain"], "pahad": ["mountain"], "पहाड": ["mountain"], 
        "flower": ["flower"], "flowers": ["flower"], "phool": ["flower"], "फूल": ["flower"],
        "baby": ["baby", "child"], "bachcha": ["baby", "child"], "bacha": ["baby", "child"], "बच्चा": ["baby", "child"], "बच्चे": ["baby", "child"],
        "shirt": ["shirt", "clothing"], "kurta": ["kurta", "clothing"], "कुर्ता": ["kurta", "clothing"], "dress": ["dress", "clothing"],
        "saree": ["saree", "clothing"], "साडी": ["saree", "clothing"], 
        "shoes": ["shoe"], "shoe": ["shoe"], "joote": ["shoe"], "जूते": ["shoe"],
        "watch": ["watch"], "ghadi": ["watch"], "घडी": ["watch"], 
        "bag": ["bag"], "sunset": ["sunset", "sky"], "sunrise": ["sunrise", "sky"], "sky": ["sky"], "aasman": ["sky"], "आसमान": ["sky"],
        "tree": ["tree"], "trees": ["tree"], "ped": ["tree"], "पेड": ["tree"], 
        "building": ["building"], "temple": ["temple"], "mandir": ["temple"], "मंदिर": ["temple"],
        "bill": ["document", "receipt"], "receipt": ["document", "receipt"], "document": ["document"],
        "glasses": ["glasses"], "sunglasses": ["glasses"], "chashma": ["glasses"], "चश्मा": ["glasses"],
        "laptop": ["laptop"], "phone": ["phone"], "bird": ["bird"], "chidiya": ["bird"], "चिडिया": ["bird"],
        "friends": ["person"], "family": ["person"], "selfie": ["person"], "selfies": ["person"],
    ]

    // MARK: Sections of the app

    /// Single words and phrases that name a part of the app. Keys are the section ids.
    static let sectionWords: [String: Set<String>] = [
        "shopping": ["shopping", "shop", "शॉपिंग", "kharidari", "खरीदारी"],
        "finance": ["finance", "money", "spending", "expenses", "expense", "kharcha", "खर्च", "फाइनेंस", "paisa", "paise", "पैसा", "पैसे", "खर्चा"],
        "investments": ["investments", "investment", "portfolio", "stocks", "निवेश", "nivesh", "इन्वेस्टमेंट"],
        "fitness": ["fitness", "workout", "workouts", "फिटनेस", "वर्कआउट"],
        "photos": ["photos", "photo", "gallery", "फोटो", "फोटोज", "गैलरी", "तस्वीरें", "तस्वीर"],
        "music": ["music", "म्यूजिक", "संगीत"],
        "memory": ["memory", "memories", "मेमोरी", "yaadein"],
        "integrations": ["integrations", "integration", "इंटीग्रेशन", "connections"],
        "security": ["security", "privacy", "सिक्योरिटी", "प्राइवेसी", "सुरक्षा"],
        "settings": ["settings", "setting", "सेटिंग्स", "सेटिंग", "preferences"],
        "history": ["history", "हिस्ट्री", "इतिहास"],
        "activity": ["activity", "एक्टिविटी"],
    ]
    static let sectionPhrases: [(phrase: [String], id: String)] = [
        (["device", "control"], "device_control"), (["agent", "activity"], "activity"), (["kill", "switch"], "security"),
        (["डिवाइस", "कंट्रोल"], "device_control"), (["एजेंट", "एक्टिविटी"], "activity"),
        (["mutual", "funds"], "investments"), (["mutual", "fund"], "investments"),
    ]
    static let openVerbs: Set<String> = [
        "open", "go", "goto", "show", "launch", "switch", "kholo", "kholna", "khol", "kholiye", "chalo", "jao", "dikhao",
        "dikha", "dikhana", "dikhaiye", "खोलो", "खोलना", "खोल", "खोलिए", "दिखाओ", "दिखा", "दिखाइए", "चलो", "जाओ",
    ]
    static let openFillers: Set<String> = [
        "the", "my", "me", "to", "tab", "section", "screen", "page", "app", "please", "zoro", "mera", "meri", "mere", "ka", "ko",
        "ki", "ke", "mujhe", "pe", "par", "मेरा", "मेरी", "मेरे", "का", "को", "की", "के", "मुझे", "पर", "में", "mein", "tak", "a", "us",
        "kar", "karo", "do", "dena", "दो", "करो", "कर", "देना", "ek", "एक", "space", "spaces", "जोरो", "जोरो", "can", "you", "could",
    ]

    // MARK: Intent triggers

    static let alarmWords: Set<String> = ["alarm", "alarms", "alaram", "अलार्म", "अलारम"]
    static let wakeWords: Set<String> = ["utha", "uthana", "jaga", "jagana", "jagado", "उठा", "उठाना", "जगा", "जगाना", "उठाओ", "जगाओ"]
    static let timerWords: Set<String> = ["timer", "timers", "टाइमर", "countdown", "stopwatch"]
    static let reminderWords: Set<String> = [
        "remind", "reminder", "reminders", "रिमाइंडर", "रिमाइंड", "reminderr", "yaad", "याद",
    ]
    static let calendarWords: Set<String> = [
        "calendar", "schedule", "agenda", "meeting", "meetings", "appointment", "appointments", "events", "event", "कैलेंडर",
        "शेड्यूल", "मीटिंग", "मीटिंग्स", "अपॉइंटमेंट", "इवेंट", "ईवेंट", "कार्यक्रम", "calender",
    ]
    static let calendarBlockers: Set<String> = [
        "add", "create", "book", "new", "banao", "bana", "set", "make", "जोडो", "जोडो", "बनाओ", "बना", "सेट", "cancel", "delete",
        "reschedule", "hatao", "हटाओ", "जोड", "जोड",
    ]
    static let playWords: Set<String> = [
        "play", "chalao", "chala", "bajao", "baja", "sunao", "suna", "चलाओ", "चला", "बजाओ", "बजा", "सुनाओ", "सुना", "chaliye", "बजाइए", "चलाइए",
    ]
    static let pauseWords: Set<String> = ["pause", "ruko", "roko", "रोको", "रुको", "रोक", "रुक", "paus", "थामो"]
    static let stopWords: Set<String> = ["stop", "band", "बंद", "off"]
    static let nextTrack: Set<String> = ["next", "skip", "agla", "agle", "agli", "अगला", "अगले", "अगली"]
    static let previousTrack: Set<String> = ["previous", "prev", "pichla", "pichle", "pichli", "पिछला", "पिछले", "पिछली", "back", "peeche", "पीछे"]
    static let musicNouns: Set<String> = [
        "music", "song", "songs", "track", "tracks", "gaana", "gana", "gaane", "gaaney", "गाना", "गाने", "म्यूजिक", "संगीत", "playing",
        "bajna", "playlist", "album", "tune",
    ]
    static let musicFillers: Set<String> = [
        "some", "the", "a", "an", "my", "please", "on", "ke", "ka", "ki", "wala", "wale", "wali", "mujhe", "do", "dena", "ek", "kuch",
        "kuchh", "for", "me", "to", "by", "from", "of", "ho", "hi", "toh", "zara", "thoda", "वाला", "वाले", "वाली", "का", "की", "के",
        "मुझे", "एक", "कुछ", "पर", "से", "जरा", "जरा", "दो", "देना", "in", "and", "सुनाओ", "me", "mein", "में", "ko", "को", "us",
        "kar", "karo", "kijiye", "कर", "करो", "कीजिए", "lagao", "लगाओ", "laga", "लगा", "vo", "wo", "वो", "woh", "yeh", "ye", "ज्यादा",
        "chalu", "चालू", "shuru", "शुरू", "start", "can", "you", "could", "would", "i", "want", "listen", "hear", "sunna", "सुनना",
    ]
    static let spotifyWords: Set<String> = ["spotify", "स्पॉटिफाई", "स्पोटिफाई"]
    static let appleMusicWords: Set<String> = ["apple", "एप्पल"]
    static let allDayCodes = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
}
