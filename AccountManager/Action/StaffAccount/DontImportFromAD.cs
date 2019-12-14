using AccountApi;
using AccountManager.Views.Dialogs;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    class DontImportFromAD : AccountAction
    {
        public DontImportFromAD() : base(
            "Negeer Directory Account",
            "Als dit account moet blijven bestaan, maar niet gelinkt is aan wisa of smartschool, dan kan je dit account negeren.",
            true
            )
        { }

        public async override Task Apply(State.Linked.LinkedStaffMember account)
        {
            IRule rule = State.App.Instance.AD.AddimportRule(AccountApi.Rule.AD_DontImportUser);
            rule.SetConfig(0, account.Directory.Account.UID);
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            if (!account.Wisa.Exists && !account.Smartschool.Exists && account.Directory.Exists)
            {
                account.Actions.Add(new DontImportFromAD());
            }
        }
    }
}
