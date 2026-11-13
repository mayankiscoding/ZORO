import Foundation

/// Everything Siri says on ZORO's behalf that is not the server's own reply, in the owner's language.
/// Tone follows docs/design/voice-and-copy.md: what happened, then what to do; no apologies; formal "आप";
/// no first-person verbs, so no grammatical gender is needed. Brand names stay in Latin script.
public struct IntentCopy: Sendable, Equatable {
    public let language: ZoroLanguage

    public init(_ language: ZoroLanguage) { self.language = language }

    private func pick(_ en: String, _ hi: String, _ hinglish: String) -> String {
        switch language {
        case .english: en
        case .hindi: hi
        case .hinglish: hinglish
        }
    }

    // MARK: Asking for values

    public var askPrompt: String {
        pick("What should I ask ZORO?", "ZORO से क्या पूछना है?", "ZORO se kya poochna hai?")
    }
    public var playPrompt: String { pick("What should ZORO play?", "ZORO क्या चलाए?", "ZORO kya chalaye?") }
    public var rememberPrompt: String {
        pick("What should ZORO remember?", "ZORO को क्या याद रखना है?", "ZORO ko kya yaad rakhna hai?")
    }
    public var photoPrompt: String { pick("What's in the photo?", "फ़ोटो में क्या है?", "Photo mein kya hai?") }
    public var periodPrompt: String { pick("For which period?", "किस समय का?", "Kis time ka?") }

    // MARK: Continuing in the app

    public func continuation(_ reason: IntentSuspension) -> String {
        switch reason {
        case .approval:
            pick(
                "This needs your approval. Approvals happen only in the ZORO app, so it continues there.",
                "इसके लिए आपकी मंज़ूरी चाहिए। मंज़ूरी सिर्फ़ ZORO ऐप में दी जाती है, इसलिए यह वहीं जारी रहेगा।",
                "Iske liye aapki manzoori chahiye. Manzoori sirf ZORO app mein di jaati hai, isliye yeh wahin jaari rahega.")
        case .deviceAction:
            pick(
                "This needs a step on your device, so it continues in the ZORO app.",
                "इसके लिए आपके डिवाइस पर एक कदम पूरा होना है, इसलिए यह ZORO ऐप में जारी रहेगा।",
                "Iske liye aapke device par ek step poora hona hai, isliye yeh ZORO app mein jaari rahega.")
        }
    }

    public var longReply: String {
        pick(
            "The full answer is long, so it's in the ZORO app.",
            "पूरा जवाब लंबा है, इसलिए वह ZORO ऐप में है।",
            "Poora jawab lamba hai, isliye woh ZORO app mein hai.")
    }

    public var privateReply: String {
        pick(
            "This answer has private details, so it's shown only in the ZORO app.",
            "इस जवाब में निजी जानकारी है, इसलिए यह सिर्फ़ ZORO ऐप में दिखेगा।",
            "Is jawab mein niji jaankari hai, isliye yeh sirf ZORO app mein dikhega.")
    }

    /// The owner chose not to open the app.
    public var notContinued: String {
        pick(
            "Nothing was done. Ask again in the ZORO app when you're ready.",
            "कुछ नहीं किया गया। जब चाहें, ZORO ऐप में फिर से पूछें।",
            "Kuch nahi kiya gaya. Jab chahein, ZORO app mein phir se poochhein.")
    }

    /// The app cannot come to the front from here (for example from an extension).
    public var openAppToContinue: String {
        pick(
            "Open the ZORO app and ask there to finish this.",
            "इसे पूरा करने के लिए ZORO ऐप खोलकर वहीं पूछें।",
            "Ise poora karne ke liye ZORO app kholkar wahin poochhein.")
    }

    public var openingPhotos: String {
        pick("Opening your photo search in ZORO.", "ZORO में फ़ोटो खोज खुल रही है।", "ZORO mein photo search khul rahi hai.")
    }

    // MARK: Failures

    public func failure(_ failure: IntentTurnFailure) -> String {
        switch failure {
        case .offline:
            pick(
                "Can't reach your ZORO server. Check that your Mac is awake and on Tailscale.",
                "आपके ZORO सर्वर से जुड़ नहीं पा रहे। देखें कि आपका Mac चालू है और Tailscale पर है।",
                "Aapke ZORO server se jud nahi pa rahe. Dekhein ki aapka Mac chalu hai aur Tailscale par hai.")
        case .timeout:
            pick(
                "ZORO took too long to answer, so the request was stopped. Open ZORO to try again.",
                "ZORO ने जवाब देने में बहुत देर लगाई, इसलिए अनुरोध रोक दिया गया। फिर से कोशिश करने के लिए ZORO खोलें।",
                "ZORO ne jawab dene mein bahut der lagayi, isliye request rok di gayi. Phir se koshish karne ke liye ZORO kholein.")
        case .notPaired:
            pick(
                "This device isn't connected to your ZORO server yet. Open ZORO to pair it.",
                "यह डिवाइस अभी आपके ZORO सर्वर से नहीं जुड़ा है। जोड़ने के लिए ZORO खोलें।",
                "Yeh device abhi aapke ZORO server se nahi juda hai. Jodne ke liye ZORO kholein.")
        case .unauthorized:
            pick(
                "Your ZORO server didn't accept this device. Open ZORO to pair it again.",
                "आपके ZORO सर्वर ने इस डिवाइस को स्वीकार नहीं किया। फिर से जोड़ने के लिए ZORO खोलें।",
                "Aapke ZORO server ne is device ko sweekar nahi kiya. Phir se jodne ke liye ZORO kholein.")
        case .paused:
            pick(
                "ZORO is paused. Turn it back on in Security and privacy.",
                "ZORO रुका हुआ है। Security and privacy में इसे फिर से चालू करें।",
                "ZORO ruka hua hai. Security and privacy mein ise phir se chalu karein.")
        case .cancelled:
            pick("Stopped.", "रोक दिया गया।", "Rok diya gaya.")
        case .empty:
            pick(
                "ZORO finished without an answer. Open ZORO to see the conversation.",
                "ZORO से कोई जवाब नहीं आया। बातचीत देखने के लिए ZORO खोलें।",
                "ZORO se koi jawab nahi aaya. Baatcheet dekhne ke liye ZORO kholein.")
        case .notConfigured:
            pick(
                "ZORO isn't ready for Siri yet. Open ZORO once, then try again.",
                "Siri के लिए ZORO अभी तैयार नहीं है। एक बार ZORO खोलें, फिर कोशिश करें।",
                "Siri ke liye ZORO abhi taiyaar nahi hai. Ek baar ZORO kholein, phir koshish karein.")
        case .server(_, let message, _):
            pick("This couldn't be finished: \(message)", "यह पूरा नहीं हो सका: \(message)", "Yeh poora nahi ho saka: \(message)")
        }
    }

    // MARK: Privacy mode

    public var privateModeOn: String { pick("Private mode is on.", "प्राइवेट मोड चालू है।", "Private mode chalu hai.") }
    public var privateModeAlreadyOn: String {
        pick("Private mode is already on.", "प्राइवेट मोड पहले से चालू है।", "Private mode pehle se chalu hai.")
    }
    public var privateModeUnchanged: String {
        pick(
            "Private mode wasn't changed. Switch it in Security and privacy in the ZORO app.",
            "प्राइवेट मोड नहीं बदला गया। इसे ZORO ऐप में Security and privacy से बदलें।",
            "Private mode nahi badla gaya. Ise ZORO app mein Security and privacy se badlein.")
    }

    // MARK: Tip

    /// "Say: “Hey Siri, ask ZORO …”" in the owner's language, with the spoken phrase from the catalogue.
    public var siriTip: String {
        pick(
            "Say: “Hey Siri, \(ZoroShortcutPhrases.tipPhrase(.english))”",
            "कहें: “Hey Siri, \(ZoroShortcutPhrases.tipPhrase(.hindi))”",
            "Kahein: “Hey Siri, \(ZoroShortcutPhrases.tipPhrase(.hinglish))”")
    }

    public var siriTipDetail: String {
        pick(
            "Siri hands your question to ZORO and reads the answer. Approvals still happen here.",
            "Siri आपका सवाल ZORO तक पहुँचाता है और जवाब सुनाता है। मंज़ूरी फिर भी यहीं दी जाती है।",
            "Siri aapka sawaal ZORO tak pahunchata hai aur jawab sunata hai. Manzoori phir bhi yahin di jaati hai.")
    }

    /// Language of a reply as reported by the server ("hi", "hi-Latn", "hinglish", "en-IN" …).
    public static func language(ofReply code: String?, fallback: ZoroLanguage) -> ZoroLanguage {
        guard let code = code?.lowercased(), !code.isEmpty else { return fallback }
        if code == "hinglish" || (code.hasPrefix("hi") && code.contains("latn")) { return .hinglish }
        if code.hasPrefix("hi") { return .hindi }
        if code.hasPrefix("en") { return .english }
        return fallback
    }
}
