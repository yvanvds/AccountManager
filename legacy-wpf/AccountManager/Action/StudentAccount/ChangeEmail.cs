using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class ChangeEmail : AccountAction
    {
        public ChangeEmail() : base(
            "Wijzig het email adres",
            "e-mail voor een leerling moet de student suffix bevatten",
            true, true)
        { }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            String mail;
            mail = linkedAccount.Directory.Account.Mail;
            String suffix = State.App.Instance.AD.AzureDomain.Value;
            if(!mail.Contains("@student."))
            {
                mail = mail.Replace(suffix, "student." + suffix);
            }

            if (!linkedAccount.Directory.Account.Mail.Contains("@student."))
            {
                
                linkedAccount.Directory.Account.Mail = mail;

            }
            if (!linkedAccount.Smartschool.Account.Mail.Contains("@student."))
            {
                linkedAccount.Smartschool.Account.Mail = mail;
                await AccountApi.Smartschool.AccountManager.Save(linkedAccount.Smartschool.Account, "").ConfigureAwait(false);
            }
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (!account.Directory.Account.Mail.Contains("@student.") || !account.Smartschool.Account.Mail.Contains("@student."))
            {
                account.Directory.FlagWarning();
                account.Actions.Add(new ChangeEmail());
                account.OK = false;
            }
        }
    }
}
