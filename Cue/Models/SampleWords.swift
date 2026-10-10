import Foundation
import SwiftData

/// Twelve example words, so a new wall has something on it.
enum SampleWords {
    private struct Sample {
        var word: String
        var hoursAgo: Double
        var sentence: String
        var source: String
        var entry: WordEntry
    }

    private static let refreshedKey = "sampleEntries.v3"
    private static let imagesKey = "sampleImages.v3"

    /// Samples saved before the word page changed shape keep their old entries; give them the new ones once.
    @MainActor
    static func refreshEntriesOnce(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: refreshedKey) else { return }
        let words = (try? context.fetch(FetchDescriptor<Word>())) ?? []
        for word in words where word.entry?.origin == nil {
            if let sample = samples.first(where: { $0.word == word.text }) { word.entry = entry(for: sample) }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: refreshedKey)
    }

    /// Samples saved before the pictures changed style keep their old pictures; give them the bundled ones once.
    @MainActor
    static func refreshImagesOnce(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: imagesKey) else { return }
        let words = (try? context.fetch(FetchDescriptor<Word>())) ?? []
        for word in words where word.entry?.origin == nil {
            guard samples.contains(where: { $0.word == word.text }),
                  let url = Bundle.main.url(forResource: "sample-\(word.text)", withExtension: "png"),
                  let data = try? Data(contentsOf: url) else { continue }
            word.imageData = ImageNormalizer.trimmed(data) ?? data
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: imagesKey)
    }

    /// The scenes the sample pictures were drawn from, so a sample can be redrawn like any other word.
    private static let pictureIdeas: [String: String] = [
        "serendipity": "an old cloth-bound book lying open, with a pressed four-leaf clover discovered between its pages, a happy accidental find",
        "ubiquitous": "a desktop world globe on a brass stand with dozens of miniature smartphones stuck all over its surface, as if they are everywhere",
        "ephemeral": "a dandelion seed head on its stem with half of its seeds drifting away in the breeze, fleeting and fragile",
        "resilient": "a small green sprout pushing up through a crack in a broken chunk of concrete, thriving despite everything",
        "meticulous": "an open mechanical pocket watch movement with fine steel tweezers placing one tiny gear, a jeweler's loupe and three tiny screwdrivers lined up perfectly beside it",
        "nostalgia": "an open old shoebox of childhood keepsakes (a worn teddy bear, a cassette tape, a tin toy robot) with a faded instant photo of a child propped up in front",
        "wanderlust": "a worn vintage leather suitcase with a brass compass, a rolled paper map and a small paper airplane resting on top, longing to travel",
        "vivid": "an open hardcover book with a miniature, realistic thunderstorm cloud billowing up out of its pages, rain pouring onto the paper and a tiny bolt of lightning, a description coming to life",
        "procrastinate": "a young adult sprawled in a small armchair, grinning at a phone, next to a towering stack of unfinished paperwork with a ringing red alarm clock on top, all ignored",
        "commute": "a sleepy office worker sitting on a single bus seat with earphones in, holding a takeaway coffee, a work bag on the lap, a yellow grab pole beside the seat",
        "candid": "a printed essay on a clipboard covered in frank red-pen circles, crossings-out and margin marks, its text shown only as soft gray lines, with an uncapped red pen lying across it",
        "inevitable": "a curving line of dominoes in mid-fall, the falling wave just about to reach the last standing domino",
    ]

    private static func entry(for sample: Sample) -> WordEntry {
        var entry = sample.entry
        entry.pictureIdea = pictureIdeas[sample.word]
        return entry
    }

    /// Whether this is the app's very first launch here: no earlier launch has refreshed the samples' entries (see
    /// `refreshEntriesOnce`, which marks it). Read before that runs.
    static var isFirstLaunch: Bool { !UserDefaults.standard.bool(forKey: refreshedKey) }

    @MainActor
    /// On the app's very first launch only, and only into a wall with nothing on it once what the user's iCloud holds
    /// has been looked at (`CloudSync`): a wall coming back from iCloud, after the app was installed again or on
    /// another device, has had them already. They used to go in on every launch that found no words, so a wall the
    /// user had emptied filled up with them again and the empty wall was never seen (2026-10-07).
    static func insertIntoEmptyWall(_ context: ModelContext) {
        guard (try? context.fetchCount(FetchDescriptor<Word>())) == 0 else { return }
        let now = Date.now
        for sample in samples {
            let word = Word(
                text: sample.word, entry: entry(for: sample), sentence: sample.sentence, source: sample.source,
                createdAt: now.addingTimeInterval(-sample.hoursAgo * 3_600)
            )
            if let url = Bundle.main.url(forResource: "sample-\(sample.word)", withExtension: "png") {
                word.imageData = (try? Data(contentsOf: url)).map { ImageNormalizer.trimmed($0) ?? $0 }
            }
            context.insert(word)
        }
        try? context.save()
    }

    private static let samples: [Sample] = [
        Sample(
            word: "serendipity", hoursAgo: 2,
            sentence: "Finding this little café was pure serendipity — we only came in to get out of the rain.",
            source: "旅行日记", 
            entry: WordEntry(
                phoneticUK: "ˌserənˈdɪpəti", phoneticUS: "ˌserənˈdɪpəti",
                summary: "n. 机缘巧合",
                parts: [.init(pos: "noun", senses: [
                    .init(chinese: "机缘巧合",
                          english: "the fact of finding interesting or valuable things by chance",
                          example: "Meeting her there was pure serendipity.",
                          exampleChinese: "在那里遇见她纯属机缘巧合。"),
                ])],
                etymology: "1754 年由英国作家 Horace Walpole 创造，取自波斯童话《锡兰三王子》（The Three Princes of Serendip）。Serendip 是斯里兰卡的旧称，故事里的王子总能意外发现他们并没有在找的东西。",
                note: "偏书面，讲一次意外的美好发现或相遇时最自然。和 luck 不同，它强调「没在找，却碰上了好事」。",
                collocations: [
                    .init(phrase: "pure serendipity", chinese: "纯属机缘巧合"),
                    .init(phrase: "by serendipity", chinese: "机缘巧合地"),
                ]
            )
        ),
        Sample(
            word: "ubiquitous", hoursAgo: 5,
            sentence: "Smartphones have become ubiquitous on the morning train.",
            source: "The Economist",
            entry: WordEntry(
                phoneticUK: "juːˈbɪkwɪtəs", phoneticUS: "juːˈbɪkwɪtəs",
                summary: "adj. 无处不在的",
                parts: [.init(pos: "adjective", senses: [
                    .init(chinese: "无处不在的",
                          english: "seeming to be everywhere or in several places at the same time",
                          example: "Coffee shops have become ubiquitous in the city.",
                          exampleChinese: "咖啡店在这座城市里已经随处可见。"),
                ])],
                etymology: "来自拉丁语 ubique，意思是「到处，无论哪里」。",
                note: "偏书面，常见于新闻、评论和论文；日常聊天说 everywhere 更自然。常带一点「多到让人习以为常」的意味。",
                collocations: [
                    .init(phrase: "become ubiquitous", chinese: "变得随处可见"),
                    .init(phrase: "almost ubiquitous", chinese: "几乎无处不在"),
                    .init(phrase: "the ubiquitous smartphone", chinese: "人手一部的智能手机"),
                ]
            )
        ),
        Sample(
            word: "ephemeral", hoursAgo: 26,
            sentence: "Social media fame is often ephemeral; most viral stars are forgotten within a month.",
            source: "BBC News",
            entry: WordEntry(
                phoneticUK: "ɪˈfemərəl", phoneticUS: "ɪˈfemərəl",
                summary: "adj. 短暂的",
                parts: [.init(pos: "adjective", senses: [
                    .init(chinese: "短暂的",
                          english: "lasting or used for only a short period of time",
                          example: "Fashions are ephemeral, but style is eternal.",
                          exampleChinese: "时尚转瞬即逝，风格却是永恒的。"),
                ])],
                etymology: "来自希腊语 ephēmeros，「只持续一天的」：epi（在……上）+ hēmera（一天）。",
                note: "书面语，比 short-lived 更文雅，常用来形容美好却留不住的东西；口语里说 doesn't last long 更自然。",
                collocations: [
                    .init(phrase: "ephemeral beauty", chinese: "转瞬即逝的美"),
                    .init(phrase: "the ephemeral nature of fame", chinese: "名气的短暂"),
                ]
            )
        ),
        Sample(
            word: "resilient", hoursAgo: 30,
            sentence: "Children are remarkably resilient and adapt quickly to new schools.",
            source: "心理学课",
            entry: WordEntry(
                phoneticUK: "rɪˈzɪliənt", phoneticUS: "rɪˈzɪliənt",
                summary: "adj. 有韧性的",
                parts: [.init(pos: "adjective", senses: [
                    .init(chinese: "有韧性的",
                          english: "able to feel better quickly after something unpleasant happens",
                          example: "She's a resilient person who never stays down for long.",
                          exampleChinese: "她是个韧性很强的人，从不会消沉太久。"),
                    .init(chinese: "有弹性的",
                          english: "able to return to its original shape after being bent or pressed",
                          example: "These running shoes have a resilient rubber sole.",
                          exampleChinese: "这双跑鞋的橡胶鞋底很有弹性。"),
                ])],
                etymology: "来自拉丁语 resilire，「弹回」：re-（回）+ salire（跳）。",
                note: "人、经济、社区、系统都能用，在新闻和职场里很常见。名词是 resilience，常说 mental resilience（心理韧性）。",
                collocations: [
                    .init(phrase: "remarkably resilient", chinese: "非常有韧性"),
                    .init(phrase: "a resilient economy", chinese: "有韧性的经济"),
                    .init(phrase: "build resilience", chinese: "培养韧性"),
                ]
            )
        ),
        Sample(
            word: "meticulous", hoursAgo: 50,
            sentence: "She keeps meticulous notes of every experiment.",
            source: "实验室",
            entry: WordEntry(
                phoneticUK: "məˈtɪkjələs", phoneticUS: "məˈtɪkjələs",
                summary: "adj. 一丝不苟的",
                parts: [.init(pos: "adjective", senses: [
                    .init(chinese: "一丝不苟的",
                          english: "paying careful attention to every detail",
                          example: "He's meticulous about keeping his desk tidy.",
                          exampleChinese: "他对保持桌面整洁一丝不苟。"),
                ])],
                etymology: "来自拉丁语 meticulosus，「胆小的」（metus，害怕）。怕出错，于是格外小心。",
                note: "褒义，夸人做事细致，工作评价、推荐信里很常见；如果是挑剔到烦人，说 fussy 或 nitpicky。",
                collocations: [
                    .init(phrase: "meticulous attention to detail", chinese: "对细节一丝不苟"),
                    .init(phrase: "be meticulous about something", chinese: "在某事上一丝不苟"),
                    .init(phrase: "meticulous planning", chinese: "周密的计划"),
                ]
            )
        ),
        Sample(
            word: "nostalgia", hoursAgo: 74,
            sentence: "The smell of rain on hot pavement fills me with nostalgia for summers at my grandmother's.",
            source: "散文",
            entry: WordEntry(
                phoneticUK: "nɒˈstældʒə", phoneticUS: "nɑːˈstældʒə",
                summary: "n. 怀旧",
                parts: [.init(pos: "noun", senses: [
                    .init(chinese: "怀旧",
                          english: "a feeling of sadness mixed with pleasure when you think of happy times in the past",
                          example: "The old song filled him with nostalgia.",
                          exampleChinese: "那首老歌勾起了他的怀旧之情。"),
                ])],
                etymology: "来自希腊语 nostos（回家）+ algos（痛苦），原意是「思乡病」。",
                note: "日常和书面都常用。怀念什么说 nostalgia for something，不说 nostalgia of；形容词是 nostalgic。",
                collocations: [
                    .init(phrase: "a wave of nostalgia", chinese: "一阵怀旧之情"),
                    .init(phrase: "nostalgia for the past", chinese: "对过去的怀念"),
                    .init(phrase: "feel nostalgic", chinese: "感到怀旧"),
                ]
            )
        ),
        Sample(
            word: "wanderlust", hoursAgo: 98,
            sentence: "A month of working from home gave me serious wanderlust.",
            source: "推特",
            entry: WordEntry(
                phoneticUK: "ˈwɒndəlʌst", phoneticUS: "ˈwɑːndərlʌst",
                summary: "n. 旅行癖",
                parts: [.init(pos: "noun", senses: [
                    .init(chinese: "旅行癖",
                          english: "a strong desire to travel",
                          example: "Her wanderlust took her to over thirty countries.",
                          exampleChinese: "对旅行的热爱让她去了三十多个国家。"),
                ])],
                etymology: "直接借自德语：wandern（远足、漫游）+ Lust（渴望）。",
                note: "轻松、带点文艺感，常见于旅行博客、社交媒体和杂志；正式写作里少用。",
                collocations: [
                    .init(phrase: "satisfy your wanderlust", chinese: "满足想去旅行的心"),
                    .init(phrase: "full of wanderlust", chinese: "满心想去远方"),
                ]
            )
        ),
        Sample(
            word: "vivid", hoursAgo: 122,
            sentence: "He gave a vivid description of the storm.",
            source: "小说",
            entry: WordEntry(
                phoneticUK: "ˈvɪvɪd", phoneticUS: "ˈvɪvɪd",
                summary: "adj. 生动的",
                parts: [.init(pos: "adjective", senses: [
                    .init(chinese: "生动的",
                          english: "producing very clear, powerful and detailed images in the mind",
                          example: "He gave a vivid description of the storm.",
                          exampleChinese: "他把那场暴风雨描述得栩栩如生。"),
                    .init(chinese: "鲜艳的",
                          english: "very bright in colour",
                          example: "The garden was full of vivid red and orange flowers.",
                          exampleChinese: "花园里开满了鲜艳的红花和橙花。"),
                ])],
                etymology: "来自拉丁语 vividus，「有生气的」（vivere，活着）。",
                note: "日常和书面都常用，最常搭配记忆、描述、想象和颜色。说一堂课很生动，用 engaging 或 lively，不用 vivid。",
                collocations: [
                    .init(phrase: "vivid memories", chinese: "清晰的记忆"),
                    .init(phrase: "a vivid imagination", chinese: "丰富的想象力"),
                    .init(phrase: "in vivid detail", chinese: "绘声绘色地"),
                    .init(phrase: "vivid colours", chinese: "鲜艳的颜色"),
                ]
            )
        ),
        Sample(
            word: "procrastinate", hoursAgo: 146,
            sentence: "I tend to procrastinate when a task feels too big.",
            source: "自己写的",
            entry: WordEntry(
                phoneticUK: "prəˈkræstɪneɪt", phoneticUS: "prəˈkræstɪneɪt",
                summary: "v. 拖延",
                parts: [.init(pos: "verb", senses: [
                    .init(chinese: "拖延",
                          english: "to delay doing something that you should do, usually because you do not want to do it",
                          example: "I always procrastinate when I have an essay to write.",
                          exampleChinese: "一有论文要写，我就会拖延。"),
                ])],
                etymology: "来自拉丁语 procrastinare：pro-（向前）+ crastinus（明天的），即「推到明天」。",
                note: "偏书面，日常口语更常说 put off 或 leave it until the last minute；名词 procrastination 很常用。",
                collocations: [
                    .init(phrase: "stop procrastinating", chinese: "别再拖了"),
                    .init(phrase: "procrastinate on something", chinese: "在某事上拖延"),
                    .init(phrase: "put off doing something", chinese: "推迟做某事（口语）"),
                ]
            )
        ),
        Sample(
            word: "commute", hoursAgo: 170,
            sentence: "My daily commute takes about forty minutes by bus.",
            source: "口语课",
            entry: WordEntry(
                phoneticUK: "kəˈmjuːt", phoneticUS: "kəˈmjuːt",
                summary: "v. 通勤  n. 通勤路程",
                parts: [
                    .init(pos: "verb", senses: [
                        .init(chinese: "通勤",
                              english: "to travel regularly between work and home",
                              example: "She commutes to London every day.",
                              exampleChinese: "她每天通勤去伦敦上班。"),
                    ]),
                    .init(pos: "noun", senses: [
                        .init(chinese: "通勤路程",
                              english: "the journey that a person makes to and from work",
                              example: "I have a long commute.",
                              exampleChinese: "我上下班路上要花很长时间。"),
                    ]),
                ],
                etymology: "来自拉丁语 commutare「交换、改变」。19 世纪美国铁路的 commutation ticket（折价月票）让它有了「通勤」的意思。",
                note: "日常和书面都常用；通勤的人叫 commuter。说通勤要多久，常说 My commute is about forty minutes。",
                collocations: [
                    .init(phrase: "a long commute", chinese: "通勤时间长"),
                    .init(phrase: "the daily commute", chinese: "每天的通勤"),
                    .init(phrase: "commute to work", chinese: "通勤上班"),
                ]
            )
        ),
        Sample(
            word: "candid", hoursAgo: 194,
            sentence: "Thanks for your candid feedback on my essay.",
            source: "导师邮件",
            entry: WordEntry(
                phoneticUK: "ˈkændɪd", phoneticUS: "ˈkændɪd",
                summary: "adj. 坦率的",
                parts: [.init(pos: "adjective", senses: [
                    .init(chinese: "坦率的",
                          english: "saying what you think openly and honestly",
                          example: "To be candid, I don't think the plan will work.",
                          exampleChinese: "坦白说，我觉得这个计划行不通。"),
                    .init(chinese: "抓拍的（照片）",
                          english: "of a photograph: taken informally, often without the person knowing",
                          example: "The best wedding photos were the candid ones.",
                          exampleChinese: "婚礼上最好看的照片都是抓拍的。"),
                ])],
                etymology: "来自拉丁语 candidus「白色的、纯洁的」，引申为「真诚、不掩饰」。candidate（候选人）同源：古罗马的候选人穿白袍。",
                note: "语气真诚而不冒犯，常见于工作沟通和访谈；比 frank 温和，比 blunt 礼貌。",
                collocations: [
                    .init(phrase: "to be candid", chinese: "坦白说"),
                    .init(phrase: "candid feedback", chinese: "坦诚的反馈"),
                    .init(phrase: "a candid photo", chinese: "抓拍照"),
                ]
            )
        ),
        Sample(
            word: "inevitable", hoursAgo: 218,
            sentence: "Some mistakes are inevitable when you learn a new language.",
            source: "TED",
            entry: WordEntry(
                phoneticUK: "ɪnˈevɪtəbl", phoneticUS: "ɪnˈevɪtəbl",
                summary: "adj. 不可避免的",
                parts: [.init(pos: "adjective", senses: [
                    .init(chinese: "不可避免的",
                          english: "certain to happen and impossible to avoid",
                          example: "It was inevitable that they would meet again.",
                          exampleChinese: "他们注定会再次相遇。"),
                ])],
                etymology: "来自拉丁语 inevitabilis：in-（不）+ evitare（避开）。",
                note: "日常和书面都常用。the inevitable 作名词指「必然会发生的事」，比如 accept the inevitable（接受现实）。",
                collocations: [
                    .init(phrase: "it is inevitable that…", chinese: "……是不可避免的"),
                    .init(phrase: "almost inevitable", chinese: "几乎不可避免"),
                    .init(phrase: "accept the inevitable", chinese: "接受现实"),
                ]
            )
        ),
    ]
}
