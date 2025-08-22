using AccountApi.Azure;
using AccountManager.State.Linked;
using AccountManager.Utils;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Documents;

namespace AccountManager.Action.StudentAccount
{
    class ModifyAzureName : AccountAction
    {
        public ModifyAzureName() : base(
            "Wijzig de naam in Azure",
            "De naam in Azure komt niet overeen met de naam in Wisa",
            true,
            false
        )
        {
            CanShowDetails = true;
        }

        public override FlowDocument GetDetails(LinkedAccount account)
        {
            var result = new FlowTableCreator(true);
            result.SetHeaders(new string[] { "Wisa", "Azure" });
            result.AddRow(new List<string>() {"Roepnaam", account.Wisa.Account.FullName, account.Azure.Account.DisplayName});

            FlowDocument document = new FlowDocument();
            document.Blocks.Add(result.Create());

            return document;
        }
        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            linkedAccount.Azure.Account.ChangeGivenName(linkedAccount.Wisa.Account.PreferedName);
            linkedAccount.Azure.Account.ChangeDisplayName(linkedAccount.Wisa.Account.FullName);

            await UserManager.Instance.Update(linkedAccount.Azure.Account).ConfigureAwait(false);
        }
        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (!Utils.CompareStrings.NamesEqual(account.Wisa.Account.FullName, account.Azure.Account.DisplayName))
            {
                account.Actions.Add(new ModifyAzureName());
                account.Azure.FlagWarning();
                account.OK = false;
            }
        }
    }
}
