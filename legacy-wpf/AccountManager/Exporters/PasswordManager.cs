using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Exporters
{
    public sealed class PasswordManager
    {
        private static readonly Lazy<PasswordManager> manager = new Lazy<PasswordManager>(() => new PasswordManager());
        public static PasswordManager Instance {  get { return manager.Value; } }

        Passwords.Manager<Passwords.AccountPassword> accountPasswords = new Passwords.Manager<Passwords.AccountPassword>("Passwords.json");
        public Passwords.Manager<Passwords.AccountPassword> Accounts => accountPasswords;

        Passwords.Manager<Passwords.CoAccountPassword> coPasswords = new Passwords.Manager<Passwords.CoAccountPassword>("CoPasswords.json");
        public Passwords.Manager<Passwords.CoAccountPassword> CoAccounts => coPasswords;

        private PasswordManager() { }
    }
}
