import Foundation

extension SynonymLexicon {
    /// Everyday photo subjects. English words cover the identifiers Vision's classifier tends to use
    /// (`hat`, `baseball_hat`, `sunset_sunrise`, …); matching is by whole words, so "cap" also finds
    /// "baseball cap".
    public static let standard = SynonymLexicon(concepts: [
        Concept("hat", en: ["cap", "hat", "headwear", "baseball hat", "baseball cap", "beanie", "helmet"],
                hi: ["टोपी", "हेलमेट"], hinglish: ["topi", "topee"]),
        Concept("dog", en: ["dog", "puppy", "canine"], hi: ["कुत्ता", "कुत्ते", "पिल्ला"], hinglish: ["kutta", "kutte", "kuttaa", "doggy", "pilla"]),
        Concept("cat", en: ["cat", "kitten", "feline"], hi: ["बिल्ली", "बिल्लियाँ"], hinglish: ["billi", "billee", "bili"]),
        Concept("bird", en: ["bird", "parrot", "pigeon", "peacock"], hi: ["पक्षी", "चिड़िया", "तोता", "मोर", "कबूतर"],
                hinglish: ["chidiya", "chiriya", "pakshi", "tota", "mor", "kabutar"]),
        Concept("car", en: ["car", "automobile", "vehicle", "suv"], hi: ["गाड़ी", "कार"], hinglish: ["gaadi", "gadi", "gaari"]),
        Concept("motorcycle", en: ["motorcycle", "bike", "scooter", "motorbike"], hi: ["बाइक", "स्कूटर", "मोटरसाइकिल"],
                hinglish: ["baik", "scooty", "fatfati"]),
        Concept("bicycle", en: ["bicycle", "cycle"], hi: ["साइकिल"], hinglish: ["saikil", "cycle"]),
        Concept("food", en: ["food", "meal", "dish", "dinner", "lunch", "breakfast"], hi: ["खाना", "भोजन", "नाश्ता"],
                hinglish: ["khana", "khaana", "bhojan", "nashta", "naashta"]),
        Concept("cake", en: ["cake", "dessert", "pastry"], hi: ["केक", "मिठाई"], hinglish: ["mithai", "keik"]),
        Concept("tea", en: ["tea", "coffee", "cup", "mug"], hi: ["चाय", "कॉफ़ी", "कप"], hinglish: ["chai", "chaay", "kaafi"]),
        Concept("tree", en: ["tree", "forest", "plant"], hi: ["पेड़", "पौधा", "जंगल"], hinglish: ["ped", "pedh", "paudha", "jungle", "jangal"]),
        Concept("flower", en: ["flower", "blossom", "rose"], hi: ["फूल", "गुलाब"], hinglish: ["phool", "phul", "fool", "gulab"]),
        Concept("beach", en: ["beach", "shore", "sea", "ocean", "seashore"], hi: ["समुद्र", "समंदर", "तट", "बीच"],
                hinglish: ["samundar", "samudra", "samandar", "beech"]),
        Concept("mountain", en: ["mountain", "hill", "hills", "mountains"], hi: ["पहाड़", "पर्वत", "पहाड़ी"], hinglish: ["pahad", "pahaad", "pahar", "parvat"]),
        Concept("sky", en: ["sky", "cloud", "clouds"], hi: ["आसमान", "आकाश", "बादल"], hinglish: ["aasmaan", "asman", "aakash", "badal", "baadal"]),
        Concept("sunset", en: ["sunset", "sunrise", "sunset sunrise", "dusk", "dawn"], hi: ["सूर्यास्त", "सूर्योदय"],
                hinglish: ["suryast", "suryoday", "dhalta suraj"]),
        Concept("water", en: ["water", "river", "lake", "waterfall"], hi: ["पानी", "नदी", "झील", "झरना"], hinglish: ["paani", "pani", "nadi", "jheel", "jharna"]),
        Concept("rain", en: ["rain", "storm", "umbrella"], hi: ["बारिश", "बरसात", "छाता"], hinglish: ["baarish", "barish", "barsaat", "chhata", "chata"]),
        Concept("snow", en: ["snow", "ice"], hi: ["बर्फ़", "बर्फ"], hinglish: ["barf", "baraf"]),
        Concept("document", en: ["document", "paper", "receipt", "bill", "invoice", "text", "letter"],
                hi: ["कागज़", "कागज", "रसीद", "बिल", "दस्तावेज़"], hinglish: ["kaagaz", "kagaz", "kagaj", "raseed", "rasid", "dastavez"]),
        Concept("people", en: ["people", "person", "adult", "crowd", "group"], hi: ["लोग", "आदमी", "इंसान"],
                hinglish: ["log", "logon", "aadmi", "insaan"]),
        Concept("child", en: ["child", "baby", "kid", "toddler", "infant"], hi: ["बच्चा", "बच्ची", "बच्चे", "शिशु"],
                hinglish: ["bachcha", "bachha", "bacha", "bachchi", "bachche", "baccha"]),
        Concept("selfie", en: ["selfie", "portrait", "face"], hi: ["सेल्फ़ी", "चेहरा"], hinglish: ["selfi", "chehra"]),
        Concept("temple", en: ["temple", "shrine", "church", "mosque", "religious building"], hi: ["मंदिर", "मस्जिद", "गुरुद्वारा"],
                hinglish: ["mandir", "masjid", "gurudwara"]),
        Concept("wedding", en: ["wedding", "bride", "groom", "ceremony"], hi: ["शादी", "विवाह", "दुल्हन", "दूल्हा"],
                hinglish: ["shaadi", "shadi", "vivah", "dulhan", "dulha"]),
        Concept("celebration", en: ["celebration", "party", "birthday", "festival", "fireworks", "candle"],
                hi: ["पार्टी", "जन्मदिन", "त्योहार", "दिवाली", "होली"],
                hinglish: ["janamdin", "janmdin", "tyohar", "diwali", "holi"]),
        Concept("house", en: ["house", "home", "building", "room", "interior room"], hi: ["घर", "मकान", "कमरा"], hinglish: ["ghar", "makaan", "kamra"]),
        Concept("shoes", en: ["shoes", "shoe", "footwear", "sneaker", "sandal"], hi: ["जूते", "जूता", "चप्पल"], hinglish: ["joote", "jute", "joota", "chappal"]),
        Concept("clothing", en: ["clothing", "shirt", "dress", "jacket", "saree", "sari", "kurta", "jeans"],
                hi: ["कपड़े", "कमीज़", "साड़ी", "कुर्ता"], hinglish: ["kapde", "kapda", "kameez", "saadi", "kurti"]),
        Concept("glasses", en: ["glasses", "eyeglasses", "sunglasses", "spectacles"], hi: ["चश्मा"], hinglish: ["chashma", "chasma"]),
        Concept("bag", en: ["bag", "backpack", "handbag", "luggage", "suitcase"], hi: ["बैग", "थैला"], hinglish: ["thaila", "jhola"]),
        Concept("book", en: ["book", "books", "notebook"], hi: ["किताब", "पुस्तक", "कॉपी"], hinglish: ["kitaab", "kitab", "pustak"]),
        Concept("phone", en: ["phone", "smartphone", "cellphone", "mobile phone"], hi: ["फ़ोन", "मोबाइल"], hinglish: ["fone", "mobile"]),
        Concept("computer", en: ["computer", "laptop", "screen", "monitor", "keyboard"], hi: ["कंप्यूटर", "लैपटॉप"], hinglish: ["kampyutar", "lappy"]),
        Concept("train", en: ["train", "railway", "station"], hi: ["ट्रेन", "रेल", "रेलगाड़ी"], hinglish: ["tren", "rail", "railgadi"]),
        Concept("airplane", en: ["airplane", "aircraft", "plane", "airport"], hi: ["हवाई जहाज़", "जहाज़", "विमान"],
                hinglish: ["hawai jahaz", "jahaz", "jahaaj", "viman"]),
        Concept("cricket", en: ["cricket", "bat", "ball", "sport", "stadium"], hi: ["क्रिकेट", "गेंद", "बल्ला"], hinglish: ["kriket", "gend", "balla"]),
        Concept("night", en: ["night", "night sky", "moon", "stars"], hi: ["रात", "चाँद", "चांद", "तारे"], hinglish: ["raat", "rat", "chaand", "chand", "taare"]),
        Concept("money", en: ["money", "cash", "currency", "banknote"], hi: ["पैसे", "पैसा", "नोट"], hinglish: ["paise", "paisa", "rupaye", "rupees"]),
        Concept("screenshot", en: ["screenshot", "screen shot"], hi: ["स्क्रीनशॉट"], hinglish: ["screenshot", "ss"]),
    ])
}

/// Words that carry no search meaning ("photo of my …", "मेरी … वाली तस्वीर").
enum QueryStopwords {
    static let all: Set<String> = Set([
        // English
        "a", "an", "the", "of", "with", "in", "on", "at", "from", "my", "me", "i", "and", "or", "for", "to", "show",
        "find", "search", "get", "open", "photo", "photos", "picture", "pictures", "pic", "pics", "image", "images",
        "that", "this", "where", "wearing", "some", "any", "all", "please", "was", "is", "it", "had", "have", "having",
        "taken", "shot", "click", "clicked", "one", "those", "these",
        // Hinglish
        "mera", "meri", "mere", "wala", "wali", "wale", "waala", "waali", "ki", "ka", "ke", "ko", "se", "mein", "me",
        "dikhao", "dikha", "dhundo", "dhoondo", "khojo", "tasveer", "tasvir", "photu", "foto", "jisme", "jismein",
        "hai", "tha", "thi", "aur", "bhi", "pehna", "pehni", "pehne", "wo", "woh", "vo", "ye", "yeh", "do", "zara",
        // Hindi
        "मेरा", "मेरी", "मेरे", "वाला", "वाली", "वाले", "की", "का", "के", "को", "से", "में", "दिखाओ", "ढूंढो", "खोजो",
        "तस्वीर", "तस्वीरें", "फ़ोटो", "फोटो", "जिसमें", "है", "था", "थी", "और", "भी", "पहना", "पहनी", "वो", "यह", "ये",
    ].map(TextNormalizer.normalize))
}
