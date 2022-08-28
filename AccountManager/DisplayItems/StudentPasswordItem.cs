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
        public Prop<bool> AzurePassword { get; set;} = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolCo1Password { get; set; } = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolCo2Password { get; set; } = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolCo3Password { get; set; } = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolCo4Password { get; set; } = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolCo5Password { get; set; } = new Prop<bool>() { Value = false };
        public Prop<bool> SmartschoolCo6Password { get; set; } = new Prop<bool>() { Value = false };

        public string NewDirectoryPassword = string.Empty;
        public string NewSmartschoolPassword = string.Empty;
        public string NewAzurePassword = string.Empty;
        public string NewSmartschoolCo1Password = string.Empty;
        public string NewSmartschoolCo2Password = string.Empty;
        public string NewSmartschoolCo3Password = string.Empty;
        public string NewSmartschoolCo4Password = string.Empty;
        public string NewSmartschoolCo5Password = string.Empty;
        public string NewSmartschoolCo6Password = string.Empty;
    }
}
