using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using static AbstractAccountApi.ObservableProperties;

namespace AccountManager.DisplayItems
{
    public class StudentPasswordItem
    {
        public AccountApi.Directory.Account Account { get; }

        public StudentPasswordItem(AccountApi.Directory.Account account)
        {
            Account = account;
        }

        public string Name { get => Account.FullName; }
        public string UserName { get => Account.UID; }

        public Prop<bool> DirectoryPassword { get; set; } = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolPassword { get; set; } = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolCo1Password { get; set; } = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolCo2Password { get; set; } = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolCo3Password { get; set; } = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolCo4Password { get; set; } = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolCo5Password { get; set; } = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolCo6Password { get; set; } = new Prop<bool>() { Value = false };
    }
}
