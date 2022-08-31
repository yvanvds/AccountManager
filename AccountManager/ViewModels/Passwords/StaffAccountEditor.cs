using AccountApi;
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.ViewModels.Passwords
{
    class StaffAccountEditor : INotifyPropertyChanged
    {
        public IAsyncCommand DeleteCommand { get; private set; }
        public IAsyncCommand SaveCommand { get; private set; }
        public IAsyncCommand CopyCodeCommand { get; private set; }

        public IAsyncCommand NewNetworkPasswordCommand { get; private set; }
        public IAsyncCommand NewOffice365PasswordCommand { get; private set; }
        public IAsyncCommand NewSmartschoolPasswordCommand { get; private set; }
        public IAsyncCommand NewPasswordsCommand { get; private set; }

        public StaffAccountEditor(AccountApi.Directory.Account account)
        {
            SetAccount(account);
            DeleteCommand = new RelayAsyncCommand(DeleteAccount);
            SaveCommand = new RelayAsyncCommand(SaveAccount);
            CopyCodeCommand = new RelayAsyncCommand(CreateCopyCode);
            NewNetworkPasswordCommand = new RelayAsyncCommand(NewNetworkPassword);
            NewSmartschoolPasswordCommand = new RelayAsyncCommand(NewSmartschoolPassword);
            NewOffice365PasswordCommand = new RelayAsyncCommand(NewOffice365Password);
            NewPasswordsCommand = new RelayAsyncCommand(NewPasswords);
            DeleteEnabled = account != null;
        }

        private async Task NewPasswords()
        {

            if (account == null) return;
            bool connected = await State.App.Instance.AD.Connect().ConfigureAwait(false);
            if (!connected) return;

            AllPWIndicator = true;
            await Task.Run(async () =>
            {
                // Active Directory
                var password = AccountApi.Password.Create();
                account.SetPassword(password);

                // Smartschool
                var smartschool = AccountApi.Smartschool.GroupManager.Root.FindAccount(account.UID);
                if (smartschool != null)
                {
                    // we use accounttype student although this is staff, it is used to indicate its not about a co-account
                    bool result = await AccountApi.Smartschool.AccountManager.SetPassword(smartschool, password, AccountType.Student).ConfigureAwait(false);
                    if (!result)
                    {
                        return;
                    }
                }

                // Office365
                var office365 = AccountApi.Azure.UserManager.Instance.FindAccountByPrincipalName(account.PrincipalName);

                if (office365 != null)
                {
                    bool result = await AccountApi.Azure.UserManager.Instance.SetPassword(office365, password).ConfigureAwait(false);
                    if (!result)
                    {
                        return;
                    }
                }

                await Exporters.PasswordManager.Instance.Accounts
                    .ExportStaffPasswordToPDF(account.FullName, account.UID, account.PrincipalName, account.CopyCode.ToString(), password, password, password)
                    .ConfigureAwait(false);
            }).ConfigureAwait(false);

            
            AllPWIndicator = false;
        }

        private async Task NewSmartschoolPassword()
        {
            if (account == null) return;
            SmartschoolPWIndicator = true;
            var password = AccountApi.Password.Create();

            var smartschool = AccountApi.Smartschool.GroupManager.Root.FindAccount(account.UID);
            if (smartschool != null)
            {
                await AccountApi.Smartschool.AccountManager.SetPassword(smartschool, password, AccountType.Student).ConfigureAwait(false);

                await Exporters.PasswordManager.Instance.Accounts
                    .ExportStaffPasswordToPDF(account.FullName, account.UID, account.PrincipalName, account.CopyCode.ToString(), null, password, null)
                    .ConfigureAwait(false);
            }
            SmartschoolPWIndicator = false;
        }

        private async Task NewNetworkPassword()
        {
            if (account == null) return;
            NetworkPWIndicator = true;
            var password = AccountApi.Password.Create();
            account.SetPassword(password);

            //var google = AccountApi.Google.AccountManager.Find(account.UID);
            //if (google != null)
            //{
            //    await AccountApi.Google.AccountManager.ChangePassword(google, password).ConfigureAwait(false);
            //}

            await Exporters.PasswordManager.Instance.Accounts
                .ExportStaffPasswordToPDF(account.FullName, account.UID, account.PrincipalName, account.CopyCode.ToString(), password, null, null)
                .ConfigureAwait(false);
            NetworkPWIndicator = false;
        }

        private async Task NewOffice365Password()
        {
            if (account == null) return;
            NetworkPWIndicator = true;
            var password = AccountApi.Password.Create();

            var office365 = AccountApi.Azure.UserManager.Instance.FindAccountByPrincipalName(account.PrincipalName);

            if (office365 != null)
            {
                bool result = await AccountApi.Azure.UserManager.Instance.SetPassword(office365, password).ConfigureAwait(false);
                if (!result)
                {
                    return;
                }
            }
            await Exporters.PasswordManager.Instance.Accounts
                .ExportStaffPasswordToPDF(account.FullName, account.UID, account.PrincipalName, account.CopyCode.ToString(), null, null, password)
                .ConfigureAwait(false);

            NetworkPWIndicator = false;
        }



        private async Task CreateCopyCode()
        {
            await Task.Run(() =>
            {
                var random = new Random();
                bool valid = false;
                int code = 0;
                while (!valid)
                {
                    code = random.Next(1001, 9999);
                    valid = true;
                    foreach (var account in AccountApi.Directory.AccountManager.Staff)
                    {
                        if (code == account.CopyCode) valid = false;
                    }
                }
                CopyCode = code;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(CopyCode)));
            }).ConfigureAwait(false);
        }

        private async Task SaveAccount()
        {
            await Task.Run(() =>
            {
                SaveEnabled = false;
                AccountApi.AccountRole newRole = account.Role;
                switch (RoleIndex)
                {
                    case 0: newRole = AccountApi.AccountRole.Teacher; break;
                    case 1: newRole = AccountApi.AccountRole.Support; break;
                    case 2: newRole = AccountApi.AccountRole.IT; break;
                    case 3: newRole = AccountApi.AccountRole.Director; break;
                }
                if (account.Role != newRole) account.Role = newRole;

                string newGender = account.Gender;
                if (Gender > 6) newGender = "male";
                else if (Gender < 4) newGender = "female";
                if (account.Gender != newGender) account.Gender = newGender;
                
                if (account.FirstName != FirstName) account.FirstName = FirstName;
                if (account.LastName != LastName) account.LastName = LastName;
                if (account.CopyCode != CopyCode) account.CopyCode = CopyCode;
            }).ConfigureAwait(false);
            
        }

        private async Task DeleteAccount()
        {
            if (account == null) return;

            DeleteEnabled = false;
            SaveEnabled = false;
            await AccountApi.Directory.AccountManager.DeleteStaff(account).ConfigureAwait(false);
            var smartschool = AccountApi.Smartschool.GroupManager.Root.FindAccount(account.UID);
            if (smartschool != null)
            {
                await AccountApi.Smartschool.AccountManager.Delete(smartschool).ConfigureAwait(false);
            }
            //var google = AccountApi.Google.AccountManager.Find(account.UID);
            //if (google != null)
            //{
            //    await AccountApi.Google.AccountManager.Delete(google).ConfigureAwait(false);
            //}
            account = null;
            DeleteEnabled = true;
        }

        public event PropertyChangedEventHandler PropertyChanged = (sender, e) => { };

        AccountApi.Directory.Account account = null;

        public void SetAccount(AccountApi.Directory.Account account)
        {
            this.account = account;
            SaveEnabled = false;

            if (account != null)
            {
                DeleteEnabled = true;
                switch (account.Role)
                {
                    case AccountApi.AccountRole.Director: roleIndex = 3; break;
                    case AccountApi.AccountRole.IT: roleIndex = 2; break;
                    case AccountApi.AccountRole.Support: roleIndex = 1; break;
                    case AccountApi.AccountRole.Teacher: roleIndex = 0; break;
                    default: roleIndex = -1; break;
                }
                firstName = account.FirstName;
                lastName = account.LastName;
                copyCode = account.CopyCode;

                if (account.Gender == "male") gender = 8.0f;
                else if (account.Gender == "female") gender = 2.0f;
                else gender = 5.0f;
            } else
            {
                DeleteEnabled = false;
                roleIndex = -1;
                firstName = string.Empty;
                lastName = string.Empty;
                copyCode = 0;
                gender = 5.0f;
            }
            
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(Title)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(UID)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(CopyCodeEnabled)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(RoleIndex)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(FirstName)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(LastName)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(CopyCode)));
            PropertyChanged(this, new PropertyChangedEventArgs(nameof(Gender)));
        }

        public string Title => account == null ? "Geen Actieve Selectie" : account.FullName;

        private string firstName = string.Empty;
        public string FirstName
        {
            get => firstName;
            set
            {
                firstName = value;
                SaveEnabled = true;
            }
        }

        private string lastName = string.Empty;
        public string LastName
        {
            get => lastName;
            set
            {
                lastName = value;
                SaveEnabled = true;
            }
        }

        public string UID => account != null ? account.UID : "";

        private int copyCode = 0;
        public int CopyCode
        {
            get => copyCode;
            set
            {
                copyCode = value;
                SaveEnabled = true;
            }
        }

        private int roleIndex;
        public int RoleIndex
        {
            get => roleIndex;
            set
            {
                roleIndex = value;
                SaveEnabled = true;
                
            }
        }

        private float gender = 5.0f;
        public float Gender
        {
            get => gender;
            set
            {
                gender = value;
                SaveEnabled = true;
            }
        }

        public bool CopyCodeEnabled => CopyCode == 0;

        private bool saveEnabled = false;
        public bool SaveEnabled
        {
            get => saveEnabled;
            set
            {
                saveEnabled = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(SaveEnabled)));
            }
        }

        private bool deleteEnabled = false;
        public bool DeleteEnabled
        {
            get => deleteEnabled;
            set
            {
                deleteEnabled = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(DeleteEnabled)));
            }
        }

        private bool networkPWIndicator = false;
        public bool NetworkPWIndicator
        {
            get => networkPWIndicator;
            set
            {
                networkPWIndicator = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(NetworkPWIndicator)));
            }
        }

        private bool office365PWIndicator = false;
        public bool Office365PWIndicator
        {
            get => office365PWIndicator;
            set
            {
                office365PWIndicator = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(Office365PWIndicator)));
            }
        }

        private bool smartschoolPWIndicator = false;
        public bool SmartschoolPWIndicator
        {
            get => smartschoolPWIndicator;
            set
            {
                smartschoolPWIndicator = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(SmartschoolPWIndicator)));
            }
        }

        private bool allPWIndicator = false;
        public bool AllPWIndicator
        {
            get => allPWIndicator;
            set
            {
                allPWIndicator = value;
                PropertyChanged(this, new PropertyChangedEventArgs(nameof(AllPWIndicator)));
            }
        }
    }
}
