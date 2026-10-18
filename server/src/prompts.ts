// The prompts are the app's own files, so a word written through the server and one written with the user's own key
// are asked for in the same words.
import pictureBrief from '../../Cue/Resources/Prompts/picture-brief.txt';
import entryInstructions from '../../Cue/Resources/Prompts/entry-instructions.txt';
import entrySchema from '../../Cue/Resources/Prompts/entry-schema.txt';
import saferBriefInstructions from '../../Cue/Resources/Prompts/safer-brief-instructions.txt';
import pictureStyle from '../../Cue/Resources/Prompts/picture-style.txt';
import chatManner from '../../Cue/Resources/Prompts/chat-manner.txt';
import chatWall from '../../Cue/Resources/Prompts/chat-wall.txt';
import chatWord from '../../Cue/Resources/Prompts/chat-word.txt';
import decideInstructions from '../../Cue/Resources/Prompts/decide-instructions.txt';
import speechInstructions from '../../Cue/Resources/Prompts/speech-instructions.txt';
import offerInstructions from '../../Cue/Resources/Prompts/offer-instructions.txt';
import offerSchema from '../../Cue/Resources/Prompts/offer-schema.txt';
import deckTool from '../../Cue/Resources/Prompts/deck-tool.txt';
import noteInstructions from '../../Cue/Resources/Prompts/note-instructions.txt';
import noteSchema from '../../Cue/Resources/Prompts/note-schema.txt';
import splitInstructions from '../../Cue/Resources/Prompts/split-instructions.txt';
import splitSchema from '../../Cue/Resources/Prompts/split-schema.txt';
import countInstructions from '../../Cue/Resources/Prompts/count-instructions.txt';
import countChoices from '../../Cue/Resources/Prompts/count-choices.txt';

/** A prompt with its {{placeholders}} filled in, as the app fills them (`Prompts.text`). */
function fill(text: string, values: Record<string, string>): string {
  return text.replace(/\{\{(\w+)\}\}/g, (whole, name: string) => values[name] ?? whole);
}

export const prompts = {
  entryInstructions: fill(entryInstructions, { pictureBrief }),
  /** Parsed and sent as written: the model writes the fields in this order. */
  entrySchema: JSON.parse(entrySchema) as unknown,
  saferBriefInstructions: fill(saferBriefInstructions, { pictureBrief }),
  pictureStyle,
  chat(kind: 'wall' | 'word', lines: string[]): string {
    return chatManner + (kind === 'wall'
      ? fill(chatWall, { saved: lines.join('\n') })
      : fill(chatWord, { page: lines.join('\n') }));
  },
  decideInstructions,
  speechInstructions,
  /** For what an answer offers to keep: the words already kept, which it never offers. */
  offer(saved: string[]): string {
    return fill(offerInstructions, { saved: saved.join('\n') });
  },
  offerSchema: JSON.parse(offerSchema) as unknown,
  /** How AI hands over a deck of the wall's cards in the wall's conversation (`show_deck`). */
  deckTool: JSON.parse(deckTool) as unknown,
  /** For what of an exchange about a word is worth keeping on its card. */
  note(headword: string): string {
    return fill(noteInstructions, { headword });
  },
  noteSchema: JSON.parse(noteSchema) as unknown,
  /** For the separate things one line typed into the wall's field asks a card for. */
  splitInstructions,
  splitSchema: JSON.parse(splitSchema) as unknown,
  /** Whether one line typed into the wall's field asks for one card or several: a quick question first. */
  countInstructions,
  countChoices: JSON.parse(countChoices) as unknown,
};
