import * as path from 'path';
import { ExtensionContext } from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions
} from 'vscode-languageclient/node';

let client: LanguageClient;

export function activate(context: ExtensionContext) {
    // Navigate up from editors/vscode/out to find the C++ executable
    const serverPath = context.asAbsolutePath(
        path.join('..', '..', 'build', 'src', 'terra-analyze')
    );

    const serverOptions: ServerOptions = {
        run: { 
            command: serverPath, 
            args: ['--lsp'] 
        },
        debug: { 
            command: serverPath, 
            args: ['--lsp'] 
        }
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'terra' }],
    };

    client = new LanguageClient(
        'terraLanguageServer',
        'Terra Language Server',
        serverOptions,
        clientOptions
    );

    // Start the client. This will also launch the server
    client.start();
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) {
        return undefined;
    }
    return client.stop();
}