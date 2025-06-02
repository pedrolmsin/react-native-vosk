import { type EventSubscription } from 'react-native';
import type { VoskOptions } from './index.d';
export default class Vosk {
    /**
     * Loads the model from specified path
     *
     * @param path - Path of the model.
     *
     * @example
     *   vosk.loadModel('model-fr-fr').then(() => {
     *      setLoaded(true);
     *   });
     */
    loadModel: (path: string) => Promise<void>;
    /**
     * Asks for recording permissions then starts the recognizer.
     *
     * @param options - Optional settings for the recognizer.
     *
     * @example
     *   vosk.start().then(() => console.log("Recognizer started"));
     *
     *   vosk.start({
     *      grammar: ['cool', 'application', '[unk]'],
     *      timeout: 5000,
     *   }).catch(e => console.log(e));
     */
    start: (options?: VoskOptions) => Promise<void>;
    /**
     * Stops the recognizer. Listener should receive final result if there is any.
     */
    stop: () => void;
    /**
     * Unloads the model, also stops the recognizer.
     */
    unload: () => void;
    onResult: (cb: (e: string) => void) => EventSubscription;
    onPartialResult: (cb: (e: string) => void) => EventSubscription;
    onFinalResult: (cb: (e: string) => void) => EventSubscription;
    onError: (cb: (e: any) => void) => EventSubscription;
    onTimeout: (cb: () => void) => EventSubscription;
    private requestRecordPermission;
}
//# sourceMappingURL=index.d.ts.map