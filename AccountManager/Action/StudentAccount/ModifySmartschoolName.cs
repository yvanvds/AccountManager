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
    internal class ModifySmartschoolName : AccountAction
    {
        public ModifySmartschoolName() : base(
            "Wijzig de roepnaam in Smartschool",
            "De roepnaam in Smartschool komt niet overeen met de naam in Wisa",
            true,
            false
        )
        {
            CanShowDetails = true;
        }

        public override FlowDocument GetDetails(LinkedAccount account)
        {
            var result = new FlowTableCreator(true);
            result.SetHeaders(new string[] { "Wisa", "Smartschool" });
            result.AddRow(new List<string>() { "Roepnaam", account.Wisa.Account.PreferedName, account.Smartschool.Account.PreferedName });

            FlowDocument document = new FlowDocument();
            document.Blocks.Add(result.Create());

            return document;
        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            linkedAccount.Smartschool.Account.PreferedName = linkedAccount.Wisa.Account.PreferedName;
            await AccountApi.Smartschool.AccountManager.SaveUserParameter(linkedAccount.Smartschool.Account, "nickname", linkedAccount.Wisa.Account.PreferedName).ConfigureAwait(false);
        }
        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if(account.Wisa.Account.FirstName.Equals(account.Wisa.Account.PreferedName, StringComparison.InvariantCulture))
            {
                // If the first name is the same as the preferred name, we don't want to modify it
                return;
            }
            if (!account.Wisa.Account.PreferedName.Equals(account.Smartschool.Account.PreferedName, StringComparison.InvariantCulture))
            {
                account.Actions.Add(new ModifySmartschoolName());
                account.Smartschool.FlagWarning();
                account.OK = false;
            }
        }
    }
}
