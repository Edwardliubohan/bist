import SwiftUI

struct SupabaseConnectionFields: View {
    @ObservedObject var account: SupabaseAccountController
    @State private var projectURL = ""
    @State private var publishableKey = ""
    @State private var email = ""
    @State private var code = ""
    private var connectionSecondary: Color {
        #if os(macOS)
        muted
        #else
        Color.primary.opacity(0.75)
        #endif
    }

    var body: some View {
        Group {
            if let session = account.session {
                LabeledContent("Account", value: session.email ?? "Signed in")
                Button("Sign out") { Task { await account.signOut() } }
                    .accessibilityIdentifier("supabase.signout")
            } else if account.configuration != nil {
                if let sentTo = account.emailForCode {
                    Text("Enter the code sent to \(sentTo).")
                        .foregroundStyle(connectionSecondary).fixedSize(horizontal: false, vertical: true)
                    TextField("Email code", text: $code)
                        .accessibilityIdentifier("supabase.code")
                        #if os(iOS)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        #endif
                    Button("Sign in") { Task { await account.verifyCode(code) } }
                        .disabled(account.working || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("supabase.verify")
                }
                TextField("Email", text: $email, prompt: Text("Email").foregroundColor(connectionSecondary))
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("supabase.email")
                    #if os(iOS)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).textContentType(.emailAddress)
                    #endif
                Button(account.emailForCode == nil ? "Send sign-in code" : "Send another code") {
                    code = ""
                    Task { await account.requestCode(email: email) }
                }
                .disabled(account.working || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("supabase.send-code")
                if account.working {
                    ProgressView("Connecting…").controlSize(.small).accessibilityLabel("Connecting to Supabase")
                }
            } else {
                Text("Connect a free Supabase project, then use the same email on your Mac and iPhone.")
                    .foregroundStyle(connectionSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = account.error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).accessibilityIdentifier("supabase.account.error")
            }
            if account.configuration == nil { projectFields }
            else {
                DisclosureGroup("Project connection") {
                    projectFields
                }
            }
        }
        .onAppear {
            projectURL = account.configuration?.projectURL.absoluteString ?? ""
            publishableKey = account.configuration?.publishableKey ?? ""
            email = account.session?.email ?? ""
        }
    }

    private var projectFields: some View {
        Group {
            TextField("Project URL", text: $projectURL, prompt: Text("Project URL").foregroundColor(connectionSecondary))
                .disableAutocorrection(true)
                .accessibilityIdentifier("supabase.project.url")
                #if os(iOS)
                .keyboardType(.URL).textInputAutocapitalization(.never)
                #endif
            SecureField("Publishable key", text: $publishableKey, prompt: Text("Publishable key").foregroundColor(connectionSecondary))
                .accessibilityIdentifier("supabase.project.key")
            Button("Save connection") {
                account.configure(projectURL: projectURL, publishableKey: publishableKey)
                code = ""
            }
            .disabled(account.working || projectURL.isEmpty || publishableKey.isEmpty)
            .accessibilityIdentifier("supabase.project.save")
            Link("Open Supabase", destination: URL(string: "https://supabase.com/dashboard")!)
        }
    }
}
